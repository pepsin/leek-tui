import type { AppState, Config, Event, PortfolioItem, Quote } from './types.js';
import * as api from './api.js';
import * as portfolio from './portfolio.js';
import * as tui from './tui.js';

function setMessage(state: AppState, msg: string): void {
  state.message = msg;
}

async function refreshQuotes(state: AppState): Promise<void> {
  if (state.portfolio.length === 0) {
    state.quotes = [];
    state.lastUpdate = Math.floor(Date.now() / 1000);
    return;
  }

  try {
    const newQuotes = await api.fetchQuotes(state.portfolio);
    if (newQuotes.length > 0) {
      state.quotes = newQuotes;
    }
    state.lastUpdate = Math.floor(Date.now() / 1000);
  } catch (e: any) {
    setMessage(state, `刷新失败: ${e?.message ?? String(e)}`);
  }
}

async function performSearch(state: AppState): Promise<void> {
  if (state.searchQuery.length === 0) {
    state.searchResults = [];
    return;
  }

  try {
    const results = await api.search(state.searchQuery);
    state.searchResults = results;
    if (state.searchSelected >= state.searchResults.length) {
      state.searchSelected = 0;
    }
  } catch (e: any) {
    setMessage(state, `搜索失败: ${e?.message ?? String(e)}`);
  }
}

function addSelected(state: AppState, config: Config): void {
  if (state.searchResults.length === 0) return;
  const sel = state.searchResults[state.searchSelected];

  // Check duplicate
  const dup = state.portfolio.find(
    (item) => item.code === sel.code && item.market === sel.market
  );
  if (dup) {
    setMessage(state, `已存在: ${sel.name}`);
    return;
  }

  const newItem: PortfolioItem = {
    market: sel.market,
    code: sel.code,
    name: sel.name,
  };

  config.portfolio.push(newItem);
  state.portfolio = config.portfolio;
  setMessage(state, `已添加: ${sel.name}`);

  // Save immediately
  portfolio.save(config).catch(() => {});

  // Refresh quotes immediately
  refreshQuotes(state).catch(() => {});
}

function deleteSelected(state: AppState, config: Config): void {
  if (state.portfolio.length === 0 || state.selected >= state.portfolio.length) return;

  const deleted = state.portfolio[state.selected];
  const name = deleted.name;

  config.portfolio.splice(state.selected, 1);
  state.portfolio = config.portfolio;
  if (state.selected >= state.portfolio.length && state.portfolio.length > 0) {
    state.selected = state.portfolio.length - 1;
  }

  setMessage(state, `已删除: ${name}`);

  // Save immediately
  portfolio.save(config).catch(() => {});

  // Refresh quotes
  refreshQuotes(state).catch(() => {});
}

// ------------------------------------------------------------------
// Main loop
// ------------------------------------------------------------------

export async function run(): Promise<void> {
  const config = await portfolio.load();

  // Enforce minimum refresh interval (3s) — leek-fund performance tip
  const refreshInterval = Math.max(3, config.refreshInterval);

  tui.init();

  const state: AppState = {
    mode: 'normal',
    quotes: [],
    portfolio: config.portfolio,
    selected: 0,
    searchQuery: '',
    searchResults: [],
    searchSelected: 0,
    message: '',
    lastUpdate: 0,
    running: true,
    needRefresh: true,
  };

  // Handle graceful exit
  const cleanup = () => {
    state.running = false;
    tui.deinit();
  };
  process.on('SIGINT', cleanup);
  process.on('SIGTERM', cleanup);

  // Initial data fetch
  await refreshQuotes(state);
  let lastRefresh = Math.floor(Date.now() / 1000);
  let searchDirty = false;
  let searchDebounce = 0;

  try {
    while (state.running) {
      const event = await tui.readEvent(state.mode);

      if (event.type !== 'none') {
        switch (state.mode) {
          case 'normal': {
            switch (event.type) {
              case 'quit':
                state.running = false;
                break;
              case 'add_mode':
                state.mode = 'search';
                state.searchQuery = '';
                state.searchResults = [];
                searchDirty = false;
                searchDebounce = 0;
                break;
              case 'delete_item':
                if (state.portfolio.length > 0) {
                  state.mode = 'confirm_delete';
                }
                break;
              case 'up':
                if (state.selected > 0) state.selected--;
                break;
              case 'down':
                if (state.selected + 1 < state.portfolio.length) state.selected++;
                break;
            }
            break;
          }

          case 'search': {
            switch (event.type) {
              case 'cancel':
                state.mode = 'normal';
                state.searchResults = [];
                searchDirty = false;
                break;
              case 'select':
                addSelected(state, config);
                state.mode = 'normal';
                state.searchResults = [];
                searchDirty = false;
                break;
              case 'up':
                if (state.searchSelected > 0) state.searchSelected--;
                break;
              case 'down':
                if (state.searchSelected + 1 < state.searchResults.length) {
                  state.searchSelected++;
                }
                break;
              case 'backspace': {
                // Remove last Unicode character (not just last byte)
                const arr = Array.from(state.searchQuery);
                arr.pop();
                state.searchQuery = arr.join('');
                searchDirty = true;
                searchDebounce = 0;
                break;
              }
              case 'char': {
                state.searchQuery += event.value;
                searchDirty = true;
                searchDebounce = 0;
                break;
              }
            }
            break;
          }

          case 'confirm_delete': {
            switch (event.type) {
              case 'select':
                deleteSelected(state, config);
                state.mode = 'normal';
                break;
              case 'char': {
                if (event.value === 'y' || event.value === 'Y') {
                  deleteSelected(state, config);
                }
                state.mode = 'normal';
                break;
              }
              case 'cancel':
                state.mode = 'normal';
                break;
            }
            break;
          }
        }
      }

      // Debounced search (~300ms)
      if (searchDirty) {
        searchDebounce++;
        if (searchDebounce >= 10) {
          await performSearch(state);
          searchDirty = false;
          searchDebounce = 0;
        }
      }

      // Periodic refresh
      const now = Math.floor(Date.now() / 1000);
      if (now - lastRefresh >= refreshInterval) {
        await refreshQuotes(state);
        lastRefresh = now;
      }

      tui.render(state);

      // ~100ms tick
      await new Promise((r) => setTimeout(r, 30));
    }
  } finally {
    tui.deinit();
    await portfolio.save(config);
  }
}
