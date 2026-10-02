//! 应用配置管理
//!
//! 处理数据库初始化之前需要读取的配置（如数据库路径）。
//! 配置以 JSON 文件存储在应用安装目录下的 `config.json`。

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use tracing::{debug, info, warn};

/// 日志文件大小上限：10 MB
pub const DEFAULT_LOG_MAX_SIZE: u64 = 10 * 1024 * 1024;

/// 应用配置
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct AppConfig {
    /// 自定义数据目录（包含数据库和图片），为 None 时使用默认路径
    #[serde(default)]
    pub data_path: Option<String>,

    /// 迁移请求：重启后补齐最终快照，成功打开目标库才切换 data_path。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending_data_path: Option<String>,

    /// 是否将日志写入文件（默认 false）
    #[serde(default)]
    pub log_to_file: Option<bool>,

    /// 是否以管理员权限运行（默认 false）
    /// 启用后应用在启动时通过计划任务或 UAC 弹窗自行提权
    #[serde(default)]
    pub run_as_admin: Option<bool>,
}

impl AppConfig {
    /// 从配置文件加载
    pub fn load() -> Self {
        let config_path = get_config_path();

        if config_path.exists() {
            match fs::read_to_string(&config_path) {
                Ok(content) => match serde_json::from_str(&content) {
                    Ok(config) => {
                        debug!("Configuration loaded from {:?}", config_path);
                        return config;
                    }
                    Err(e) => {
                        warn!("Failed to parse config file: {}", e);
                    }
                },
                Err(e) => {
                    warn!("Failed to read config file: {}", e);
                }
            }
        }

        debug!("Using default configuration");
        Self::default()
    }

    /// 保存配置到文件
    pub fn save(&self) -> Result<(), String> {
        let config_path = get_config_path();

        // 确保父目录存在
        if let Some(parent) = config_path.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }

        let content = serde_json::to_string_pretty(self).map_err(|e| e.to_string())?;

        let temporary = config_path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
        let result = (|| {
            use std::io::Write;
            let mut file = fs::File::create(&temporary).map_err(|e| e.to_string())?;
            file.write_all(content.as_bytes())
                .map_err(|e| e.to_string())?;
            file.sync_all().map_err(|e| e.to_string())?;
            drop(file);
            fs::rename(&temporary, &config_path).map_err(|e| e.to_string())
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result?;

        info!("Configuration saved to {:?}", config_path);
        Ok(())
    }

    /// 获取数据库路径
    pub fn get_db_path(&self) -> PathBuf {
        if let Some(dir) = self.custom_data_dir() {
            return dir.join("clipboard.db");
        }
        crate::database::get_default_db_path()
    }

    /// 获取图片存储路径
    pub fn get_images_path(&self) -> PathBuf {
        if let Some(dir) = self.custom_data_dir() {
            return dir.join("images");
        }
        crate::database::get_default_images_path()
    }

    /// 获取日志文件路径
    pub fn get_log_path(&self) -> PathBuf {
        self.get_data_dir().join("app.log")
    }

    /// 是否启用文件日志
    pub fn is_log_to_file(&self) -> bool {
        self.log_to_file.unwrap_or(true)
    }

    /// 获取数据目录路径
    pub fn get_data_dir(&self) -> PathBuf {
        if let Some(dir) = self.custom_data_dir() {
            return dir;
        }
        crate::database::get_default_db_path()
            .parent()
            .map_or_else(|| PathBuf::from("."), std::path::Path::to_path_buf)
    }

    fn custom_data_dir(&self) -> Option<PathBuf> {
        self.data_path
            .as_ref()
            .filter(|path| !path.is_empty())
            .map(PathBuf::from)
    }
}

/// 获取配置文件路径（固定在安装目录）
fn get_config_path() -> PathBuf {
    crate::database::get_app_dir().join("config.json")
}

/// 复制锁定连接的一致快照；调用方负责暂存目录的发布和配置提交。
pub(crate) fn migrate_data(
    source: &rusqlite::Connection,
    old_path: &Path,
    staging: &Path,
    destination: &Path,
) -> Result<MigrationResult, String> {
    fs::create_dir_all(staging).map_err(|e| e.to_string())?;
    let db_path = staging.join("clipboard.db");
    {
        let mut target = rusqlite::Connection::open(&db_path).map_err(|e| e.to_string())?;
        let backup = rusqlite::backup::Backup::new(source, &mut target)
            .map_err(|e| format!("初始化迁移备份失败: {e}"))?;
        backup
            .run_to_completion(100, std::time::Duration::ZERO, None)
            .map_err(|e| format!("备份数据库失败: {e}"))?;
    }
    let mut result = MigrationResult {
        db_migrated: true,
        files_copied: 1,
        bytes_copied: fs::metadata(&db_path).map_err(|e| e.to_string())?.len(),
        ..MigrationResult::default()
    };
    for name in ["images", "icons", "staged"] {
        let source = old_path.join(name);
        if source.try_exists().map_err(|e| e.to_string())? {
            copy_dir_recursive(&source, &staging.join(name), &mut result)?;
        }
    }
    result.images_migrated = staging.join("images").is_dir();
    let db = crate::database::Database::new(db_path).map_err(|e| e.to_string())?;
    rebase_asset_paths(&db.write_connection().lock(), staging, destination)?;
    Ok(result)
}

fn copy_dir_recursive(src: &Path, dst: &Path, result: &mut MigrationResult) -> Result<(), String> {
    fs::create_dir_all(dst).map_err(|e| format!("创建 {dst:?} 失败: {e}"))?;
    for entry in fs::read_dir(src).map_err(|e| e.to_string())? {
        let entry = entry.map_err(|e| e.to_string())?;
        let old_file = entry.path();
        let new_file = dst.join(entry.file_name());
        let kind = entry.file_type().map_err(|e| e.to_string())?;
        if kind.is_dir() {
            copy_dir_recursive(&old_file, &new_file, result)?;
        } else if kind.is_file() {
            let bytes = fs::copy(&old_file, &new_file)
                .map_err(|e| format!("复制 {old_file:?} 失败: {e}"))?;
            result.files_copied += 1;
            result.bytes_copied += bytes;
        } else {
            return Err(format!("不支持迁移符号链接: {old_file:?}"));
        }
    }
    Ok(())
}

/// 数据库存储绝对路径；只重定位备份中实际存在的托管资产，保留原始文件路径。
pub(crate) fn rebase_asset_paths(
    conn: &rusqlite::Connection,
    staging: &Path,
    destination: &Path,
) -> Result<(), String> {
    use crate::clipboard::file_clipboard::{decode_payload, encode_payload};
    let relocate = |value: &str, directory: &str| {
        let normalized = value.replace('\\', "/");
        let prefix = format!("{directory}/");
        let marker = format!("/{directory}/");
        let relative = normalized
            .rsplit_once(marker.as_str())
            .map(|(_, relative)| relative)
            .or_else(|| normalized.strip_prefix(prefix.as_str()))?;
        let relative = Path::new(relative);
        if relative
            .components()
            .any(|part| !matches!(part, std::path::Component::Normal(_)))
        {
            return None;
        }
        let relative = Path::new(directory).join(relative);
        staging
            .join(&relative)
            .is_file()
            .then(|| destination.join(relative).to_string_lossy().into_owned())
    };
    let transaction = conn.unchecked_transaction().map_err(|e| e.to_string())?;
    {
        let mut select = transaction
            .prepare("SELECT id, image_path, source_app_icon, file_payload FROM clipboard_items")
            .map_err(|e| e.to_string())?;
        let rows = select
            .query_map([], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                ))
            })
            .map_err(|e| e.to_string())?;
        let mut update = transaction.prepare(
            "UPDATE clipboard_items SET image_path = ?2, source_app_icon = ?3, file_payload = ?4 WHERE id = ?1",
        ).map_err(|e| e.to_string())?;
        for row in rows {
            let (id, image, icon, payload) = row.map_err(|e| e.to_string())?;
            let new_image = image.as_deref().and_then(|v| relocate(v, "images"));
            let new_icon = icon.as_deref().and_then(|v| relocate(v, "icons"));
            let mut new_payload = None;
            if let Some(mut parsed) = decode_payload(payload.as_deref()) {
                let mut changed = false;
                for file in &mut parsed.staged {
                    if let Some(path) = relocate(&file.staged, "staged") {
                        file.staged = path;
                        changed = true;
                    }
                }
                if changed {
                    new_payload = Some(encode_payload(&parsed));
                }
            }
            if new_image.is_some() || new_icon.is_some() || new_payload.is_some() {
                update
                    .execute(rusqlite::params![
                        id,
                        new_image.or(image),
                        new_icon.or(icon),
                        new_payload.or(payload),
                    ])
                    .map_err(|e| e.to_string())?;
            }
        }
    }
    transaction.commit().map_err(|e| e.to_string())
}

/// 数据迁移结果
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct MigrationResult {
    pub db_migrated: bool,
    pub images_migrated: bool,
    pub files_copied: usize,
    pub bytes_copied: u64,
    pub errors: Vec<String>,
}
