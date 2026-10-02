import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import debounce from "lodash.debounce";
import { create } from "zustand";
import { cancelPendingFocusRestore } from "@/hooks/useInputFocus";
import { logError } from "@/lib/logger";
import { playCopySound, setupPasteSoundListeners } from "@/lib/sounds";
import { useUISettings } from "@/stores/ui-settings";

function batchResetState() {
  return { batchMode: false, selectedIds: new Set<number>(), lastSelectedIndex: -1 };
}

export interface ClipboardItem {
  id: number;
  content_type: "text" | "image" | "html" | "rtf" | "files" | "url";
  text_content: string | null;
  html_content: string | null;
  rtf_content: string | null;
  image_path: string | null;
  file_paths: string | null;
  content_hash: string;
  preview: string | null;
  byte_size: number;
  image_width: number | null;
  image_height: number | null;
  is_pinned: boolean;
  is_favorite: boolean;
  favorite_order: number;
  sort_order: number;
  created_at: string;
  updated_at: string;
  access_count: number;
  last_accessed_at: string | null;
  char_count: number | null;
  source_app_name: string | null;
  source_app_icon: string | null;
  /** 所属自定义分组 ID（null = 默认分组） */
  group_id: number | null;
  /** 所有文件是否存在（仅 files 类型，查询时计算） */
  files_valid?: boolean;
}

interface ClipboardState {
  items: ClipboardItem[];
  isLoading: boolean;
  searchQuery: string;
  selectedGroup: string | null;
  /** 当前选中的自定义分组 id，可与类型或收藏筛选组合 */
  selectedGroupId: number | null;
  /** 当前键盘高亮索引（-1 表示无） */
  activeIndex: number;
  /** 单调计数器，丢弃过期请求 */
  _fetchId: number;
  /** 视图重置计数（滚动到顶部等） */
  _resetToken: number;

  // 操作
  fetchItems: (options?: {
    search?: string;
    content_type?: string;
    limit?: number;
    offset?: number;
  }) => Promise<void>;
  setSearchQuery: (query: string) => void;
  setSelectedGroup: (group: string | null) => void;
  setSelectedGroupId: (groupId: number | null) => void;
  setActiveIndex: (index: number) => void;
  togglePin: (id: number) => Promise<void>;
  toggleFavorite: (id: number) => Promise<void>;
  moveItem: (fromId: number, toId: number) => Promise<void>;
  moveFavoriteItem: (fromId: number, toId: number) => Promise<void>;
  deleteItem: (id: number) => Promise<void>;
  copyToClipboard: (id: number) => Promise<void>;
  pasteContent: (id: number) => Promise<void>;
  pasteAsPlainText: (id: number) => Promise<void>;
  /** 清空当前分组历史，返回删除条数；失败返回 null */
  clearHistory: (contentType?: string | null) => Promise<number | null>;
  refresh: () => Promise<void>;
  /** 重置视图：清除搜索、类型筛选，滚动到顶部，刷新 */
  resetView: () => Promise<void>;
  setupListener: () => Promise<() => void>;

  // 批量选择
  batchMode: boolean;
  selectedIds: Set<number>;
  lastSelectedIndex: number;
  setBatchMode: (enabled: boolean) => void;
  toggleSelect: (id: number, index: number, shiftKey: boolean) => void;
  selectAll: () => void;
  deselectAll: () => void;
  batchDelete: () => Promise<void>;
}

async function doPaste(
  get: () => ClipboardState,
  id: number,
  command: "paste_content" | "paste_content_as_plain",
) {
  try {
    cancelPendingFocusRestore();
    const { pasteCloseWindow, pasteMoveToTop } = useUISettings.getState();
    await invoke(command, { id, closeWindow: pasteCloseWindow });
    if (pasteMoveToTop) {
      invoke("bump_item_to_top", { id }).then(() => get().refresh()).catch((e) => logError("Failed to bump item to top:", e));
    }
  } catch (error) {
    logError(`Failed to ${command}:`, error);
  }
}

export const useClipboardStore = create<ClipboardState>((set, get) => ({
  items: [],
  isLoading: false,
  searchQuery: "",
  selectedGroup: null,
  selectedGroupId: null,
  activeIndex: -1,
  _fetchId: 0,
  _resetToken: 0,

  fetchItems: async (options = {}) => {
    const state = get();
    const fetchId = state._fetchId + 1;
    set({ isLoading: true, _fetchId: fetchId });
    try {
      const group = options.content_type ?? state.selectedGroup;
      const isFavoritesView = group === "__favorites__";
      const items = await invoke<ClipboardItem[]>("get_clipboard_items", {
        search: options.search ?? (state.searchQuery || null),
        contentType: isFavoritesView ? null : group,
        pinnedOnly: false,
        favoriteOnly: isFavoritesView,
        groupId: state.selectedGroupId,
        limit: options.limit,
        offset: options.offset ?? 0,
      });
      if (get()._fetchId === fetchId) {
        set({ items, isLoading: false, activeIndex: -1 });
      }
    } catch (error) {
      if (get()._fetchId === fetchId) {
        logError("Failed to fetch items:", error);
        set({ isLoading: false });
      }
    }
  },

  setSearchQuery: (query: string) => {
    set((state) => ({
      searchQuery: query,
      _fetchId: state._fetchId + 1,
      isLoading: false,
    }));
    // 仅更新查询状态，防抖在 App.tsx 中处理
  },

  setSelectedGroup: (group: string | null) => {
    set((state) => ({
      selectedGroup: group,
      _fetchId: state._fetchId + 1,
      ...batchResetState(),
    }));
    get().fetchItems();
  },

  setSelectedGroupId: (groupId: number | null) => {
    set((state) => ({
      selectedGroupId: groupId,
      _fetchId: state._fetchId + 1,
      ...batchResetState(),
    }));
    invoke("set_active_group", { groupId }).catch((error) => {
      logError("Failed to persist active group:", error);
    });
    get().fetchItems();
  },

  setActiveIndex: (index: number) => {
    set({ activeIndex: index });
  },

  togglePin: async (id: number) => {
    try {
      await invoke<boolean>("toggle_pin", { id });
      // 刷新以获取正确排序（置顶优先）
      await get().refresh();
    } catch (error) {
      logError("Failed to toggle pin:", error);
    }
  },

  toggleFavorite: async (id: number) => {
    try {
      const newState = await invoke<boolean>("toggle_favorite", { id });
      // 在收藏视图中取消收藏时，需要刷新列表以移除该条目
      if (!newState && get().selectedGroup === "__favorites__") {
        await get().refresh();
      } else {
        set((state) => ({
          items: state.items.map((item) =>
            item.id === id ? { ...item, is_favorite: newState } : item
          ),
        }));
      }
    } catch (error) {
      logError("Failed to toggle favorite:", error);
    }
  },

  moveItem: async (fromId: number, toId: number) => {
    try {
      await invoke("move_clipboard_item", { fromId, toId });
      // 刷新以获取更新后的顺序
      await get().refresh();
    } catch (error) {
      logError("Failed to move item:", error);
    }
  },

  moveFavoriteItem: async (fromId: number, toId: number) => {
    try {
      await invoke("move_favorite_clipboard_item", { fromId, toId });
      await get().refresh();
    } catch (error) {
      logError("Failed to move favorite item:", error);
    }
  },

  deleteItem: async (id: number) => {
    try {
      await invoke("delete_clipboard_item", { id });
      set((state) => ({
        items: state.items.filter((item) => item.id !== id),
      }));
    } catch (error) {
      logError("Failed to delete item:", error);
    }
  },

  copyToClipboard: async (id: number) => {
    try {
      await invoke("copy_to_clipboard", { id });
    } catch (error) {
      logError("Failed to copy to clipboard:", error);
    }
  },

  pasteContent: async (id: number) => {
    await doPaste(get, id, "paste_content");
  },

  pasteAsPlainText: async (id: number) => {
    await doPaste(get, id, "paste_content_as_plain");
  },

  // contentType=null 时后端 Option<String> 为 None，清除所有类型（正确行为）
  clearHistory: async (contentType = null) => {
    try {
      const deleted = await invoke<number>("clear_history", {
        groupId: get().selectedGroupId,
        contentType,
      });
      await get().refresh();
      return deleted;
    } catch (error) {
      logError("Failed to clear history:", error);
      return null;
    }
  },

  refresh: async () => {
    await get().fetchItems();
  },

  resetView: async () => {
    // 仅重置搜索和类型筛选，保留分组选择
    set((state) => ({
      searchQuery: "",
      selectedGroup: null,
      ...batchResetState(),
      _resetToken: state._resetToken + 1,
      _fetchId: state._fetchId + 1,
    }));
    await get().fetchItems({ search: "" });
  },

  setupListener: async () => {
    const unlistenPasteSound = await setupPasteSoundListeners();
    let disposed = false;
    let refreshing = false;
    let refreshPending = false;

    // 合并连续捕获并定期刷新权威轻量列表，同时同步后端淘汰的记录
    const debouncedCaptureUpdate = debounce(async () => {
      if (refreshing) {
        refreshPending = true;
        return;
      }
      refreshing = true;
      refreshPending = false;
      try {
        await get().fetchItems();
        if (!disposed) playCopySound("after_success");
      } finally {
        refreshing = false;
        if (refreshPending && !disposed) void debouncedCaptureUpdate();
      }
    }, 50, { leading: false, trailing: true, maxWait: 250 });

    const unlisten = await listen<number>("clipboard-updated", (event) => {
      const id = event.payload;
      if (typeof id !== "number" || !Number.isFinite(id)) {
        return;
      }
      playCopySound("immediate");
      void debouncedCaptureUpdate();
    });
    return () => {
      disposed = true;
      debouncedCaptureUpdate.cancel();
      unlistenPasteSound();
      unlisten();
    };
  },

  // 批量选择
  batchMode: false,
  selectedIds: new Set<number>(),
  lastSelectedIndex: -1,

  setBatchMode: (enabled) => {
    set({ ...batchResetState(), batchMode: enabled });
  },

  toggleSelect: (id, index, shiftKey) => {
    const { selectedIds, lastSelectedIndex, items } = get();
    const next = new Set(selectedIds);

    if (shiftKey && lastSelectedIndex >= 0) {
      const from = Math.min(lastSelectedIndex, index);
      const to = Math.max(lastSelectedIndex, index);
      for (let i = from; i <= to; i++) {
        if (items[i]) next.add(items[i].id);
      }
    } else {
      if (next.has(id)) next.delete(id);
      else next.add(id);
    }
    set({ selectedIds: next, lastSelectedIndex: index });
  },

  selectAll: () => {
    const ids = new Set(get().items.map((item) => item.id));
    set({ selectedIds: ids });
  },

  deselectAll: () => {
    set({ selectedIds: new Set() });
  },

  batchDelete: async () => {
    const { selectedIds } = get();
    if (selectedIds.size === 0) return;
    try {
      await invoke("batch_delete_clipboard_items", { ids: Array.from(selectedIds) });
      set({ ...batchResetState() });
      await get().refresh();
    } catch (error) {
      logError("Failed to batch delete:", error);
    }
  },
}));

