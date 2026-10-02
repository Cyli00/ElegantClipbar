use crate::commands::AppState;
use crate::config::{self, AppConfig};
use crate::database;
use crate::utils::format_size;
use std::fs;
use std::path::{Path, PathBuf};

static TRANSFER_LOCK: parking_lot::Mutex<()> = parking_lot::Mutex::new(());
const IMPORT_PENDING: &str = ".clipboard-import";
const MIGRATION_PENDING: &str = ".clipboard-migration";
const DATA_MEMBERS: [&str; 6] = [
    "clipboard.db",
    "clipboard.db-wal",
    "clipboard.db-shm",
    "images",
    "icons",
    "staged",
];

struct TemporaryDirectory(PathBuf);

impl TemporaryDirectory {
    fn new(parent: &Path) -> Result<Self, String> {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        let path = parent.join(format!(".clipboard-transfer-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&path).map_err(|e| e.to_string())?;
        Ok(Self(path))
    }
}

impl Drop for TemporaryDirectory {
    fn drop(&mut self) {
        if self.0.exists()
            && let Err(error) = fs::remove_dir_all(&self.0)
        {
            tracing::warn!(
                "Failed to remove temporary transfer directory {:?}: {error}",
                self.0
            );
        }
    }
}

fn remove_path(path: &Path) -> Result<(), String> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_dir() => fs::remove_dir_all(path),
        Ok(_) => fs::remove_file(path),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.to_string()),
    }
    .map_err(|e| format!("删除 {path:?} 失败: {e}"))
}

fn write_marker(path: &Path, content: &[u8]) -> Result<(), String> {
    use std::io::Write;
    let mut file = fs::File::create(path).map_err(|e| e.to_string())?;
    file.write_all(content).map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())
}

fn chrono_timestamp() -> String {
    chrono::Local::now().format("%Y%m%d_%H%M%S").to_string()
}

fn add_dir_to_zip(
    zip: &mut zip::ZipWriter<std::fs::File>,
    dir: &std::path::Path,
    prefix: &str,
    options: zip::write::SimpleFileOptions,
) -> Result<(), String> {
    if !dir.exists() || !dir.is_dir() {
        return Ok(());
    }

    for entry in std::fs::read_dir(dir).map_err(|e| e.to_string())? {
        let entry = entry.map_err(|e| e.to_string())?;
        let path = entry.path();
        let name = format!("{}/{}", prefix, entry.file_name().to_string_lossy());
        let kind = entry.file_type().map_err(|e| e.to_string())?;
        if kind.is_dir() {
            add_dir_to_zip(zip, &path, &name, options)?;
        } else if kind.is_file() {
            zip.start_file(&name, options).map_err(|e| e.to_string())?;
            let mut file = std::fs::File::open(&path).map_err(|e| e.to_string())?;
            std::io::copy(&mut file, zip).map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

/// 仅接受相对路径；成员白名单在解包时进一步验证。
fn sanitize_zip_relative_path(name: &str) -> Option<std::path::PathBuf> {
    use std::path::{Component, Path, PathBuf};

    let raw = Path::new(name);
    if raw.is_absolute() || name.contains('\\') || name.contains(':') {
        return None;
    }

    let mut clean = PathBuf::new();
    for component in raw.components() {
        match component {
            Component::Normal(seg) => clean.push(seg),
            Component::CurDir => {}
            // 拒绝根/前缀/父目录防止路径穿越
            Component::RootDir | Component::Prefix(_) | Component::ParentDir => return None,
        }
    }

    if clean.as_os_str().is_empty() {
        return None;
    }

    Some(clean)
}

fn validate_backup(db_path: &Path) -> Result<(), String> {
    let conn =
        rusqlite::Connection::open_with_flags(db_path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .map_err(|e| format!("无效的备份数据库: {e}"))?;
    let integrity: String = conn
        .query_row("PRAGMA integrity_check", [], |row| row.get(0))
        .map_err(|e| format!("数据库完整性检查失败: {e}"))?;
    if integrity != "ok" {
        return Err(format!("数据库完整性检查失败: {integrity}"));
    }
    let tables: i64 = conn.query_row(
        "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name IN ('clipboard_items', 'settings')",
        [], |row| row.get(0),
    ).map_err(|e| e.to_string())?;
    if tables != 2 {
        return Err("数据库不是 ElegantClipboard 备份".into());
    }
    drop(conn);

    // 在暂存副本上运行与正式启动完全相同的旧版本迁移。
    let db = database::Database::new(db_path.to_path_buf())
        .map_err(|e| format!("备份数据库不兼容: {e}"))?;
    let conn = db.write_connection();
    let conn = conn.lock();
    conn.prepare(
        "SELECT id, content_type, text_content, html_content, rtf_content, image_path,
                file_paths, file_payload, content_hash, semantic_hash, preview, byte_size,
                image_width, image_height, is_pinned, is_favorite, favorite_order, sort_order,
                created_at, updated_at, access_count, last_accessed_at, char_count,
                source_app_name, source_app_icon, group_id FROM clipboard_items LIMIT 0",
    )
    .map_err(|e| format!("备份数据库不兼容: {e}"))?;
    conn.prepare("SELECT key, value, updated_at FROM settings LIMIT 0")
        .map_err(|e| e.to_string())?;
    conn.prepare("SELECT id, name, color, sort_order, created_at FROM groups LIMIT 0")
        .map_err(|e| e.to_string())?;
    let mut check = conn
        .prepare("PRAGMA foreign_key_check")
        .map_err(|e| e.to_string())?;
    if check
        .query([])
        .map_err(|e| e.to_string())?
        .next()
        .map_err(|e| e.to_string())?
        .is_some()
    {
        return Err("备份数据库存在无效的分组引用".into());
    }
    Ok(())
}

fn stage_import(archive_path: &Path, data_dir: &Path) -> Result<u32, String> {
    let pending = data_dir.join(IMPORT_PENDING);
    if pending.exists() {
        return Err("已有待导入数据，请先重启应用".into());
    }
    let staging = TemporaryDirectory::new(data_dir)?;
    let file = fs::File::open(archive_path).map_err(|e| e.to_string())?;
    let mut archive = zip::ZipArchive::new(file).map_err(|e| format!("无效的 ZIP 文件: {e}"))?;
    let mut files = 0;
    let mut has_db = false;
    let mut names = std::collections::HashSet::new();
    for index in 0..archive.len() {
        let mut entry = archive.by_index(index).map_err(|e| e.to_string())?;
        let relative = sanitize_zip_relative_path(entry.name())
            .ok_or_else(|| format!("无效的备份成员: {}", entry.name()))?;
        let mut parts = relative.components();
        let root = parts
            .next()
            .and_then(|part| part.as_os_str().to_str())
            .unwrap_or("");
        let is_db = relative == Path::new("clipboard.db") && !entry.is_dir();
        if (!is_db && !["images", "icons", "staged"].contains(&root))
            || (!entry.is_dir() && !is_db && parts.next().is_none())
            || entry
                .unix_mode()
                .is_some_and(|mode| mode & 0o170000 == 0o120000)
            || !names.insert(relative.to_string_lossy().to_lowercase())
        {
            return Err(format!("不支持的备份成员: {}", entry.name()));
        }
        let output = staging.0.join(&relative);
        if entry.is_dir() {
            fs::create_dir_all(&output).map_err(|e| e.to_string())?;
        } else {
            if let Some(parent) = output.parent() {
                fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            }
            let mut output = fs::File::create(&output).map_err(|e| e.to_string())?;
            std::io::copy(&mut entry, &mut output).map_err(|e| e.to_string())?;
            output.sync_all().map_err(|e| e.to_string())?;
            files += 1;
            has_db |= is_db;
        }
    }
    if !has_db {
        return Err("ZIP 文件中未找到 clipboard.db".into());
    }
    validate_backup(&staging.0.join("clipboard.db"))?;
    {
        let db =
            database::Database::new(staging.0.join("clipboard.db")).map_err(|e| e.to_string())?;
        config::rebase_asset_paths(&db.write_connection().lock(), &staging.0, data_dir)?;
    }
    // 唯一发布点：失败解包或数据库验证绝不会创建启动任务。
    fs::rename(&staging.0, &pending).map_err(|e| e.to_string())?;
    Ok(files)
}

fn rollback_install(data_dir: &Path, pending: &Path) -> Result<(), String> {
    remove_path(&pending.join("committed"))?;
    let journal = pending.join("originals.json");
    if journal.exists() {
        let originals: [bool; 6] =
            serde_json::from_slice(&fs::read(&journal).map_err(|e| e.to_string())?)
                .map_err(|e| format!("无法读取导入恢复记录: {e}"))?;
        for (name, existed) in DATA_MEMBERS.iter().zip(originals).rev() {
            let live = data_dir.join(name);
            let backup = pending.join("backup").join(name);
            if backup.exists() {
                remove_path(&live)?;
                fs::rename(&backup, &live).map_err(|e| format!("恢复 {name} 失败: {e}"))?;
            } else if !existed {
                remove_path(&live)?;
            }
        }
    }
    remove_path(pending)
}

fn cleanup_committed(pending: &Path) -> Result<(), String> {
    // 先移除回滚意图。清理备份中断后，绝不能把已提交的新库回滚到残缺备份。
    remove_path(&pending.join("originals.json"))?;
    remove_path(pending)
}

/// 返回 true 表示上一次提交已完成或已恢复，不能再次应用同一任务。
fn recover_install(data_dir: &Path, pending: &Path) -> Result<bool, String> {
    if pending.join("committed").exists() {
        cleanup_committed(pending)?;
        return Ok(true);
    }
    if pending.join("originals.json").exists() {
        rollback_install(data_dir, pending)?;
        return Ok(true);
    }
    Ok(false)
}

fn install_pending(
    data_dir: &Path,
    pending: &Path,
    mut open: impl FnMut(&Path) -> Result<database::Database, String>,
    finalize: impl FnOnce() -> Result<(), String>,
) -> Result<database::Database, String> {
    let result = (|| {
        validate_backup(&pending.join("clipboard.db"))?;
        fs::create_dir(pending.join("backup")).map_err(|e| e.to_string())?;
        let originals = DATA_MEMBERS.map(|name| data_dir.join(name).exists());
        let journal = serde_json::to_vec(&originals).map_err(|e| e.to_string())?;
        write_marker(&pending.join("originals.tmp"), &journal)?;
        fs::rename(
            pending.join("originals.tmp"),
            pending.join("originals.json"),
        )
        .map_err(|e| e.to_string())?;
        // 先完整备份，再安装；恢复只需判断每个原文件是否已移入 backup。
        for (name, existed) in DATA_MEMBERS.iter().zip(originals) {
            if existed {
                fs::rename(data_dir.join(name), pending.join("backup").join(name))
                    .map_err(|e| format!("备份 {name} 失败: {e}"))?;
            }
        }
        for name in DATA_MEMBERS {
            let source = pending.join(name);
            if source.exists() {
                fs::rename(source, data_dir.join(name))
                    .map_err(|e| format!("安装 {name} 失败: {e}"))?;
            }
        }
        let db = open(&data_dir.join("clipboard.db"))?;
        // 只有正式路径真正打开成功后才能提交；进程中断也有明确恢复依据。
        write_marker(&pending.join("committed"), b"committed")?;
        finalize()?;
        Ok(db)
    })();
    match result {
        Ok(db) => {
            if let Err(error) = cleanup_committed(pending) {
                tracing::warn!("Committed transfer backup cleanup failed: {error}");
            }
            Ok(db)
        }
        Err(error) => {
            // db 已离开闭包并关闭，Windows 下也可恢复原数据库。
            rollback_install(data_dir, pending)
                .map_err(|rollback| format!("{error}; 回滚失败: {rollback}"))?;
            Err(error)
        }
    }
}

fn open_database_file(path: &Path) -> Result<database::Database, String> {
    database::Database::new(path.to_path_buf()).map_err(|e| e.to_string())
}

fn open_with_import(data_dir: &Path) -> Result<database::Database, String> {
    let pending = data_dir.join(IMPORT_PENDING);
    if pending.exists() && !recover_install(data_dir, &pending)? {
        match install_pending(data_dir, &pending, open_database_file, || Ok(())) {
            Ok(db) => return Ok(db),
            Err(error) if pending.exists() => return Err(error),
            Err(error) => tracing::error!("Import rejected; original data restored: {error}"),
        }
    }
    open_database_file(&data_dir.join("clipboard.db"))
}

fn finish_migration(
    source: &database::Database,
    source_dir: &Path,
    destination: &Path,
    finalize: impl FnOnce() -> Result<(), String>,
) -> Result<database::Database, String> {
    let pending = destination.join(MIGRATION_PENDING);
    // 配置仍指向源库：即使目标文件已装好，也尚未完成迁移提交。
    // 保留并恢复目标原数据，不能将上次进程中断当成成功清理备份。
    rollback_install(destination, &pending)?;
    let staging = TemporaryDirectory::new(destination)?;
    config::migrate_data(
        &source.write_connection().lock(),
        source_dir,
        &staging.0,
        destination,
    )?;
    fs::rename(&staging.0, &pending).map_err(|e| e.to_string())?;
    install_pending(destination, &pending, open_database_file, finalize)
}

pub(crate) fn open_database(config: &mut AppConfig) -> Result<database::Database, String> {
    open_database_with_save(config, AppConfig::save)
}

fn open_database_with_save(
    config: &mut AppConfig,
    mut save: impl FnMut(&AppConfig) -> Result<(), String>,
) -> Result<database::Database, String> {
    let source_dir = config.get_data_dir();
    // 配置已切换但备份清理被中断时，只清理已提交的迁移。
    let migration = source_dir.join(MIGRATION_PENDING);
    if migration.exists() {
        recover_install(&source_dir, &migration)?;
    }
    let source = open_with_import(&source_dir)?;
    let Some(destination) = config.pending_data_path.clone() else {
        return Ok(source);
    };
    let destination = PathBuf::from(destination);
    let mut next = config.clone();
    next.data_path = Some(destination.to_string_lossy().into_owned());
    next.pending_data_path = None;
    match finish_migration(&source, &source_dir, &destination, || save(&next)) {
        Ok(db) => {
            *config = next;
            Ok(db)
        }
        Err(error) => {
            // 尽力取消失败任务；配置不可写也不能阻止使用健康的源库。
            config.pending_data_path = None;
            if let Err(save_error) = save(config) {
                tracing::warn!("Failed to clear pending migration configuration: {save_error}");
            }
            tracing::error!("Data migration failed; continuing with source database: {error}");
            Ok(source)
        }
    }
}

#[tauri::command]
pub fn get_default_data_path() -> String {
    let config = AppConfig::load();
    config.get_data_dir().to_string_lossy().to_string()
}

#[tauri::command]
pub fn get_original_default_path() -> String {
    database::get_default_db_path()
        .parent()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_default()
}

#[tauri::command]
pub fn check_path_has_data(path: String) -> bool {
    let p = std::path::PathBuf::from(&path);
    p.join("clipboard.db").exists()
}

#[tauri::command]
pub fn cleanup_data_at_path(path: String) -> Result<(), String> {
    use std::fs;
    let p = std::path::PathBuf::from(&path);

    for ext in &["", "-wal", "-shm"] {
        let db_file = p.join(format!("clipboard.db{ext}"));
        if db_file.exists() {
            fs::remove_file(&db_file).map_err(|e| format!("删除 {db_file:?} 失败: {e}"))?;
        }
    }

    let images_dir = p.join("images");
    if images_dir.exists() {
        fs::remove_dir_all(&images_dir).map_err(|e| format!("删除图片目录失败: {e}"))?;
    }

    let icons_dir = p.join("icons");
    if icons_dir.exists() {
        fs::remove_dir_all(&icons_dir).map_err(|e| format!("删除图标目录失败: {e}"))?;
    }

    Ok(())
}

#[tauri::command]
pub fn set_data_path(path: String) -> Result<(), String> {
    let _transfer = TRANSFER_LOCK.lock();
    let mut config = AppConfig::load();
    config.data_path = if path.is_empty() { None } else { Some(path) };
    config.pending_data_path = None;
    config.save()
}

#[tauri::command]
pub fn migrate_data_to_path(
    new_path: String,
    state: tauri::State<'_, std::sync::Arc<AppState>>,
) -> Result<config::MigrationResult, String> {
    let _transfer = TRANSFER_LOCK.lock();
    let mut config = AppConfig::load();
    if config.pending_data_path.is_some() || config.get_data_dir().join(IMPORT_PENDING).exists() {
        return Err("已有待处理的数据操作，请先重启应用".into());
    }
    let old_path = fs::canonicalize(config.get_data_dir()).map_err(|e| e.to_string())?;
    fs::create_dir_all(&new_path).map_err(|e| e.to_string())?;
    let new_path = fs::canonicalize(new_path).map_err(|e| e.to_string())?;
    if old_path.starts_with(&new_path) || new_path.starts_with(&old_path) {
        return Err("源目录与目标目录不能相同或相互包含".into());
    }
    if !new_path.join("clipboard.db").exists()
        && ["images", "icons", "staged"]
            .iter()
            .any(|name| new_path.join(name).exists())
    {
        return Err("目标目录包含非剪贴板数据，请选择空目录".into());
    }
    let pending = new_path.join(MIGRATION_PENDING);
    recover_install(&new_path, &pending)?;
    remove_path(&pending)?;
    state.monitor.pause();
    let result = (|| {
        let staging = TemporaryDirectory::new(&new_path)?;
        let conn = state.db.write_connection();
        let conn = conn.lock();
        let active_path = conn.path().ok_or("无法确定当前数据库路径")?;
        if fs::canonicalize(active_path).map_err(|e| e.to_string())?
            != fs::canonicalize(config.get_db_path()).map_err(|e| e.to_string())?
        {
            return Err("数据路径已更改，请先重启应用".into());
        }
        let result = config::migrate_data(&conn, &old_path, &staging.0, &new_path)?;
        validate_backup(&staging.0.join("clipboard.db"))?;
        fs::rename(&staging.0, &pending).map_err(|e| e.to_string())?;
        // 不切换活动数据根。重启会再次快照，包含此处释放写锁后的所有提交。
        config.pending_data_path = Some(new_path.to_string_lossy().into_owned());
        if let Err(error) = config.save() {
            remove_path(&pending)?;
            return Err(error);
        }
        Ok(result)
    })();
    state.monitor.resume();
    result
}

#[tauri::command]
pub async fn export_data(
    app: tauri::AppHandle,
    state: tauri::State<'_, std::sync::Arc<AppState>>,
) -> Result<String, String> {
    use std::fs::{self, File};
    use std::io::Write;
    use tauri_plugin_dialog::DialogExt;
    use zip::ZipWriter;
    use zip::write::SimpleFileOptions;

    let config = AppConfig::load();
    let data_dir = config.get_data_dir();

    let export_db = data_dir.join("clipboard.db.export");
    {
        let src_conn = state.db.write_connection();
        let src_conn = src_conn.lock();
        let _ = fs::remove_file(&export_db);
        let mut dst_conn =
            rusqlite::Connection::open(&export_db).map_err(|e| format!("创建备份文件失败: {e}"))?;
        let backup = rusqlite::backup::Backup::new(&src_conn, &mut dst_conn)
            .map_err(|e| format!("初始化备份失败: {e}"))?;
        backup
            .run_to_completion(100, std::time::Duration::from_millis(0), None)
            .map_err(|e| format!("执行备份失败: {e}"))?;
    }

    let timestamp = chrono_timestamp();
    let default_name = format!("ElegantClipboard_backup_{timestamp}.zip");
    let dest = app
        .dialog()
        .file()
        .set_title("导出数据")
        .set_file_name(&default_name)
        .add_filter("ZIP 压缩文件", &["zip"])
        .blocking_save_file();

    let dest_path = if let Some(p) = dest {
        p.to_string()
    } else {
        let _ = fs::remove_file(&export_db);
        return Err("用户取消了导出".to_string());
    };

    let file = File::create(&dest_path).map_err(|e| format!("创建文件失败: {e}"))?;
    let mut zip = ZipWriter::new(file);
    let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);

    zip.start_file("clipboard.db", options)
        .map_err(|e| e.to_string())?;
    zip.write_all(&fs::read(&export_db).map_err(|e| format!("读取数据库副本失败: {e}"))?)
        .map_err(|e| e.to_string())?;
    let _ = fs::remove_file(&export_db);

    add_dir_to_zip(&mut zip, &data_dir.join("images"), "images", options)?;

    add_dir_to_zip(&mut zip, &data_dir.join("icons"), "icons", options)?;

    add_dir_to_zip(&mut zip, &data_dir.join("staged"), "staged", options)?;

    zip.finish().map_err(|e| e.to_string())?;

    let size = fs::metadata(&dest_path).map_or(0, |m| m.len());
    Ok(format!("导出成功 ({})", format_size(size)))
}

#[tauri::command]
pub async fn import_data(app: tauri::AppHandle) -> Result<String, String> {
    use tauri_plugin_dialog::DialogExt;

    let src = app
        .dialog()
        .file()
        .set_title("导入数据")
        .add_filter("ZIP 压缩文件", &["zip"])
        .blocking_pick_file();

    let src_path = match src {
        Some(p) => p.to_string(),
        None => return Err("用户取消了导入".to_string()),
    };

    let _transfer = TRANSFER_LOCK.lock();
    let config = AppConfig::load();
    if config.pending_data_path.is_some() {
        return Err("已有待迁移数据，请先重启应用".into());
    }
    let files_extracted = stage_import(Path::new(&src_path), &config.get_data_dir())?;

    Ok(format!(
        "导入成功，共恢复 {files_extracted} 个文件，应用即将重启"
    ))
}

#[tauri::command]
pub fn restart_app(app: tauri::AppHandle) {
    crate::admin_launch::perform_restart(&app);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn test_directory() -> TemporaryDirectory {
        TemporaryDirectory::new(&std::env::temp_dir()).unwrap()
    }

    fn database_with_text(directory: &Path, text: &str) -> database::Database {
        let db = open_database_file(&directory.join("clipboard.db")).unwrap();
        insert_text(&db, text);
        db
    }

    fn insert_text(db: &database::Database, text: &str) {
        db.write_connection().lock().execute(
            "INSERT INTO clipboard_items (content_type, text_content, content_hash, semantic_hash)
             VALUES ('text', ?1, ?1, ?1)",
            [text],
        ).unwrap();
    }

    fn texts(db: &database::Database) -> Vec<String> {
        let conn = db.read_connection();
        let conn = conn.lock();
        let mut query = conn
            .prepare("SELECT text_content FROM clipboard_items ORDER BY id")
            .unwrap();
        query
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    }

    fn write_archive(path: &Path, members: &[(&str, &[u8])]) {
        let mut zip = zip::ZipWriter::new(fs::File::create(path).unwrap());
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Stored);
        for (name, content) in members {
            zip.start_file(*name, options).unwrap();
            zip.write_all(content).unwrap();
        }
        zip.finish().unwrap();
    }

    fn backup_bytes(directory: &Path) -> Vec<u8> {
        let source = rusqlite::Connection::open(directory.join("clipboard.db")).unwrap();
        let snapshot = directory.join("test-export.db");
        {
            let mut target = rusqlite::Connection::open(&snapshot).unwrap();
            rusqlite::backup::Backup::new(&source, &mut target)
                .unwrap()
                .run_to_completion(100, std::time::Duration::ZERO, None)
                .unwrap();
        }
        fs::read(snapshot).unwrap()
    }

    fn interrupt_after_backup(data: &Path, pending: &Path) {
        fs::create_dir_all(pending.join("backup")).unwrap();
        let originals = DATA_MEMBERS.map(|name| data.join(name).exists());
        write_marker(
            &pending.join("originals.json"),
            &serde_json::to_vec(&originals).unwrap(),
        )
        .unwrap();
        for (name, existed) in DATA_MEMBERS.iter().zip(originals) {
            if existed {
                fs::rename(data.join(name), pending.join("backup").join(name)).unwrap();
            }
        }
    }

    #[test]
    fn invalid_or_incompatible_backup_never_replaces_original() {
        let root = test_directory();
        let data = root.0.join("data");
        drop(database_with_text(&data, "original"));
        let archive = root.0.join("backup.zip");
        let unrelated = root.0.join("unrelated.db");
        let conn = rusqlite::Connection::open(&unrelated).unwrap();
        conn.execute_batch("CREATE TABLE unrelated (value TEXT)")
            .unwrap();
        drop(conn);
        let incompatible = root.0.join("incompatible");
        let db = database_with_text(&incompatible, "wrong schema");
        db.write_connection()
            .lock()
            .execute_batch("ALTER TABLE groups RENAME COLUMN color TO incompatible_color")
            .unwrap();
        drop(db);
        for invalid in [
            b"not a database".to_vec(),
            fs::read(unrelated).unwrap(),
            backup_bytes(&incompatible),
        ] {
            write_archive(&archive, &[("clipboard.db", &invalid)]);
            assert!(stage_import(&archive, &data).is_err());
            assert!(!data.join(IMPORT_PENDING).exists());
            let db = open_with_import(&data).unwrap();
            assert_eq!(texts(&db), ["original"]);
        }
    }

    #[test]
    fn failed_extraction_leaves_no_assets_or_future_import() {
        let root = test_directory();
        let data = root.0.join("data");
        let backup = root.0.join("backup");
        drop(database_with_text(&data, "original"));
        drop(database_with_text(&backup, "imported"));
        let bytes = backup_bytes(&backup);
        let archive = root.0.join("backup.zip");
        write_archive(
            &archive,
            &[
                ("clipboard.db", &bytes),
                ("images/new.png", b"unique-asset-content"),
            ],
        );
        let mut bytes = fs::read(&archive).unwrap();
        let position = bytes
            .windows(b"unique-asset-content".len())
            .position(|window| window == b"unique-asset-content")
            .unwrap();
        bytes[position] ^= 1;
        fs::write(&archive, bytes).unwrap();
        assert!(stage_import(&archive, &data).is_err());
        assert!(!data.join("images/new.png").exists());
        assert!(!data.join(IMPORT_PENDING).exists());
        assert!(fs::read_dir(&data).unwrap().all(|entry| {
            !entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(".clipboard-transfer-")
        }));
        assert_eq!(texts(&open_with_import(&data).unwrap()), ["original"]);
    }

    #[test]
    fn non_backup_members_are_rejected_without_overwriting_config() {
        let root = test_directory();
        let data = root.0.join("data");
        drop(database_with_text(&data, "original"));
        fs::write(data.join("config.json"), b"original config").unwrap();
        let bytes = backup_bytes(&data);
        for forbidden in [
            "config.json",
            "../outside",
            "clipboard.db-wal",
            "other/file",
        ] {
            let archive = root.0.join("backup.zip");
            write_archive(
                &archive,
                &[("clipboard.db", &bytes), (forbidden, b"replacement")],
            );
            assert!(stage_import(&archive, &data).is_err());
            assert!(!data.join(IMPORT_PENDING).exists());
        }
        assert_eq!(
            fs::read(data.join("config.json")).unwrap(),
            b"original config"
        );
    }

    #[test]
    fn valid_import_commits_database_and_assets_together() {
        let root = test_directory();
        let data = root.0.join("data");
        let backup = root.0.join("backup");
        drop(database_with_text(&data, "original"));
        drop(database_with_text(&backup, "imported"));
        fs::create_dir_all(data.join("images")).unwrap();
        fs::write(data.join("images/old.png"), b"old").unwrap();
        let bytes = backup_bytes(&backup);
        let archive = root.0.join("backup.zip");
        write_archive(
            &archive,
            &[
                ("clipboard.db", &bytes),
                ("images/new.png", b"new"),
                ("staged/hash/file.txt", b"staged"),
            ],
        );
        assert_eq!(stage_import(&archive, &data).unwrap(), 3);
        assert_eq!(fs::read(data.join("images/old.png")).unwrap(), b"old");
        assert!(!data.join("images/new.png").exists());
        let db = open_with_import(&data).unwrap();
        assert_eq!(texts(&db), ["imported"]);
        assert_eq!(fs::read(data.join("images/new.png")).unwrap(), b"new");
        assert_eq!(
            fs::read(data.join("staged/hash/file.txt")).unwrap(),
            b"staged"
        );
        assert!(!data.join("images/old.png").exists());
        assert!(!data.join(IMPORT_PENDING).exists());
    }

    #[test]
    fn failed_database_open_restores_original_database_and_assets() {
        let root = test_directory();
        let data = root.0.join("data");
        let backup = root.0.join("backup");
        drop(database_with_text(&data, "original"));
        drop(database_with_text(&backup, "imported"));
        fs::create_dir_all(data.join("images")).unwrap();
        fs::write(data.join("images/old.png"), b"old").unwrap();
        let bytes = backup_bytes(&backup);
        let archive = root.0.join("backup.zip");
        write_archive(
            &archive,
            &[("clipboard.db", &bytes), ("images/new.png", b"new")],
        );
        stage_import(&archive, &data).unwrap();
        let pending = data.join(IMPORT_PENDING);
        let result = install_pending(
            &data,
            &pending,
            |_| Err("simulated database open failure".into()),
            || Ok(()),
        );
        assert!(result.is_err());
        assert!(!pending.exists());
        assert_eq!(texts(&open_with_import(&data).unwrap()), ["original"]);
        assert_eq!(fs::read(data.join("images/old.png")).unwrap(), b"old");
        assert!(!data.join("images/new.png").exists());
    }

    #[test]
    fn interrupted_install_restores_backed_up_files_on_next_start() {
        let root = test_directory();
        let data = root.0.join("data");
        drop(database_with_text(&data, "original"));
        let pending = data.join(IMPORT_PENDING);
        interrupt_after_backup(&data, &pending);
        drop(database_with_text(&data, "interrupted import"));
        fs::create_dir_all(data.join("images")).unwrap();
        fs::write(data.join("images/partial.png"), b"partial").unwrap();
        let db = open_with_import(&data).unwrap();
        assert_eq!(texts(&db), ["original"]);
        assert!(!data.join("images").exists());
        assert!(!pending.exists());
    }

    #[test]
    fn final_migration_preserves_late_wal_commits_and_managed_asset_paths() {
        use crate::clipboard::file_clipboard::{
            FilePayload, StagedFile, decode_payload, encode_payload,
        };
        let root = test_directory();
        let source_dir = root.0.join("source");
        let destination = root.0.join("destination");
        let source = database_with_text(&source_dir, "initial");
        source
            .write_connection()
            .lock()
            .execute_batch("PRAGMA wal_autocheckpoint = 0")
            .unwrap();
        let initial = TemporaryDirectory::new(&destination).unwrap();
        config::migrate_data(
            &source.write_connection().lock(),
            &source_dir,
            &initial.0,
            &destination,
        )
        .unwrap();
        fs::rename(&initial.0, destination.join(MIGRATION_PENDING)).unwrap();
        insert_text(&source, "committed after initial snapshot");
        for (name, contents) in [
            ("images/image.png", b"image".as_slice()),
            ("icons/app.png", b"icon".as_slice()),
            ("staged/hash/file.txt", b"file".as_slice()),
        ] {
            let path = source_dir.join(name);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, contents).unwrap();
        }
        let payload = FilePayload {
            staged: vec![StagedFile {
                original: "external-original.txt".into(),
                staged: source_dir
                    .join("staged/hash/file.txt")
                    .to_string_lossy()
                    .into_owned(),
                size: 4,
            }],
            ..FilePayload::default()
        };
        source
            .write_connection()
            .lock()
            .execute(
                "UPDATE clipboard_items SET image_path = ?1, source_app_icon = ?2,
             file_payload = ?3, file_paths = ?4 WHERE text_content = 'initial'",
                rusqlite::params![
                    source_dir.join("images/image.png").to_string_lossy(),
                    source_dir.join("icons/app.png").to_string_lossy(),
                    encode_payload(&payload),
                    "[\"external-original.txt\"]",
                ],
            )
            .unwrap();
        assert!(
            source_dir
                .join("clipboard.db-wal")
                .metadata()
                .unwrap()
                .len()
                > 0
        );
        fs::write(destination.join("unrelated.txt"), b"untouched").unwrap();
        let migrated = finish_migration(&source, &source_dir, &destination, || Ok(())).unwrap();
        assert_eq!(
            texts(&migrated),
            ["initial", "committed after initial snapshot"]
        );
        assert_eq!(
            texts(&source),
            ["initial", "committed after initial snapshot"]
        );
        let (image, icon, raw, original): (String, String, String, String) = migrated
            .read_connection()
            .lock()
            .query_row(
                "SELECT image_path, source_app_icon, file_payload, file_paths
                 FROM clipboard_items WHERE text_content = 'initial'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .unwrap();
        assert_eq!(Path::new(&image), destination.join("images/image.png"));
        assert_eq!(fs::read(image).unwrap(), b"image");
        assert_eq!(Path::new(&icon), destination.join("icons/app.png"));
        assert_eq!(fs::read(icon).unwrap(), b"icon");
        let payload = decode_payload(Some(&raw)).unwrap();
        assert_eq!(
            Path::new(&payload.staged[0].staged),
            destination.join("staged/hash/file.txt")
        );
        assert_eq!(fs::read(&payload.staged[0].staged).unwrap(), b"file");
        assert_eq!(payload.staged[0].original, "external-original.txt");
        assert_eq!(original, "[\"external-original.txt\"]");
        assert_eq!(
            fs::read(destination.join("unrelated.txt")).unwrap(),
            b"untouched"
        );
        assert_eq!(
            fs::read(source_dir.join("images/image.png")).unwrap(),
            b"image"
        );
    }

    #[test]
    fn failed_migration_commit_keeps_source_and_restores_destination() {
        let root = test_directory();
        let source_dir = root.0.join("source");
        let destination = root.0.join("destination");
        let source = database_with_text(&source_dir, "source");
        drop(database_with_text(&destination, "existing destination"));
        let result = finish_migration(&source, &source_dir, &destination, || {
            Err("simulated configuration save failure".into())
        });
        assert!(result.is_err());
        assert_eq!(texts(&source), ["source"]);
        assert_eq!(
            texts(&open_with_import(&destination).unwrap()),
            ["existing destination"]
        );
        assert!(!destination.join(MIGRATION_PENDING).exists());
        insert_text(&source, "still writable");
        assert_eq!(texts(&source), ["source", "still writable"]);
    }

    #[test]
    fn interrupted_migration_before_config_commit_preserves_original_destination() {
        let root = test_directory();
        let source_dir = root.0.join("source");
        let destination = root.0.join("destination");
        let source = database_with_text(&source_dir, "source");
        drop(database_with_text(&destination, "existing destination"));
        let pending = destination.join(MIGRATION_PENDING);
        interrupt_after_backup(&destination, &pending);
        drop(database_with_text(
            &destination,
            "installed but config not saved",
        ));
        write_marker(&pending.join("committed"), b"committed").unwrap();

        let result = finish_migration(&source, &source_dir, &destination, || {
            Err("configuration still not writable".into())
        });
        assert!(result.is_err());
        assert_eq!(
            texts(&open_with_import(&destination).unwrap()),
            ["existing destination"]
        );
        assert_eq!(texts(&source), ["source"]);
    }

    #[test]
    fn unwritable_config_does_not_block_startup_with_source_database() {
        let root = test_directory();
        let source_dir = root.0.join("source");
        let destination = root.0.join("destination");
        drop(database_with_text(&source_dir, "source"));
        drop(database_with_text(&destination, "existing destination"));
        let mut config = AppConfig {
            data_path: Some(source_dir.to_string_lossy().into_owned()),
            pending_data_path: Some(destination.to_string_lossy().into_owned()),
            ..AppConfig::default()
        };
        let db = open_database_with_save(&mut config, |_| Err("permission denied".into())).unwrap();
        assert_eq!(texts(&db), ["source"]);
        insert_text(&db, "still writable");
        assert_eq!(texts(&db), ["source", "still writable"]);
        assert_eq!(config.get_data_dir(), source_dir);
        assert!(config.pending_data_path.is_none());
        assert_eq!(
            texts(&open_with_import(&destination).unwrap()),
            ["existing destination"]
        );
    }

    #[test]
    fn corrupted_pending_database_is_discarded_at_startup() {
        let root = test_directory();
        let data = root.0.join("data");
        drop(database_with_text(&data, "original"));
        let pending = data.join(IMPORT_PENDING);
        fs::create_dir(&pending).unwrap();
        fs::write(pending.join("clipboard.db"), b"corrupted after staging").unwrap();
        let db = open_with_import(&data).unwrap();
        assert_eq!(texts(&db), ["original"]);
        assert!(!pending.exists());
    }

    #[test]
    fn committed_import_cleanup_never_restores_a_partial_backup() {
        for journal_present in [true, false] {
            let root = test_directory();
            let data = root.0.join("data");
            drop(database_with_text(&data, "committed"));
            let pending = data.join(IMPORT_PENDING);
            fs::create_dir_all(pending.join("backup")).unwrap();
            fs::write(pending.join("backup/clipboard.db"), b"partial backup").unwrap();
            write_marker(&pending.join("committed"), b"committed").unwrap();
            if journal_present {
                write_marker(
                    &pending.join("originals.json"),
                    &serde_json::to_vec(&[true, false, false, false, false, false]).unwrap(),
                )
                .unwrap();
            }
            let db = open_with_import(&data).unwrap();
            assert_eq!(texts(&db), ["committed"]);
            assert!(!pending.exists());
        }
    }

    #[test]
    fn exported_nested_staged_files_survive_import() {
        let root = test_directory();
        let source = root.0.join("source");
        let destination = root.0.join("destination");
        drop(database_with_text(&source, "exported"));
        fs::create_dir_all(source.join("staged/hash")).unwrap();
        fs::write(source.join("staged/hash/document.txt"), b"document").unwrap();
        let archive = root.0.join("backup.zip");
        let mut zip = zip::ZipWriter::new(fs::File::create(&archive).unwrap());
        let options = zip::write::SimpleFileOptions::default();
        zip.start_file("clipboard.db", options).unwrap();
        zip.write_all(&backup_bytes(&source)).unwrap();
        add_dir_to_zip(&mut zip, &source.join("staged"), "staged", options).unwrap();
        zip.finish().unwrap();
        stage_import(&archive, &destination).unwrap();
        let db = open_with_import(&destination).unwrap();
        assert_eq!(texts(&db), ["exported"]);
        assert_eq!(
            fs::read(destination.join("staged/hash/document.txt")).unwrap(),
            b"document"
        );
    }

    #[test]
    fn normal_relative_path() {
        assert_eq!(
            sanitize_zip_relative_path("images/screenshot.png"),
            Some(PathBuf::from("images/screenshot.png"))
        );
    }

    #[test]
    fn simple_filename() {
        assert_eq!(
            sanitize_zip_relative_path("clipboard.db"),
            Some(PathBuf::from("clipboard.db"))
        );
    }

    #[test]
    fn rejects_parent_dir_traversal() {
        assert_eq!(sanitize_zip_relative_path("../etc/passwd"), None);
        assert_eq!(sanitize_zip_relative_path("images/../../secret"), None);
    }

    #[test]
    fn rejects_absolute_path() {
        assert_eq!(sanitize_zip_relative_path("/etc/passwd"), None);
        assert_eq!(sanitize_zip_relative_path("C:\\Windows\\system32"), None);
    }

    #[test]
    fn rejects_empty_path() {
        assert_eq!(sanitize_zip_relative_path(""), None);
    }

    #[test]
    fn rejects_dot_only() {
        assert_eq!(sanitize_zip_relative_path("."), None);
        assert_eq!(sanitize_zip_relative_path("./"), None);
    }

    #[test]
    fn strips_current_dir_prefix() {
        assert_eq!(
            sanitize_zip_relative_path("./images/test.png"),
            Some(PathBuf::from("images/test.png"))
        );
    }

    #[test]
    fn nested_path_ok() {
        assert_eq!(
            sanitize_zip_relative_path("a/b/c/d.txt"),
            Some(PathBuf::from("a/b/c/d.txt"))
        );
    }
}
