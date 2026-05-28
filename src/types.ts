export interface SearchResult {
  market: string;
  code: string;
  name: string;
  pinyin: string;
  kind: string;
}

export interface PortfolioItem {
  market: string;
  code: string;
  name: string;
}

export interface Quote {
  market: string;
  code: string;
  name: string;
  price: number;
  changePct: number;
  changeAmt: number;
}

export interface Config {
  portfolio: PortfolioItem[];
  refreshInterval: number; // seconds
}

export type Mode = 'normal' | 'search' | 'confirm_delete';

export type Event =
  | { type: 'quit' }
  | { type: 'up' }
  | { type: 'down' }
  | { type: 'select' }
  | { type: 'cancel' }
  | { type: 'add_mode' }
  | { type: 'delete_item' }
  | { type: 'backspace' }
  | { type: 'char'; value: string }
  | { type: 'resize' }
  | { type: 'none' };

export interface AppState {
  mode: Mode;
  quotes: Quote[];
  portfolio: PortfolioItem[];
  selected: number;
  searchQuery: string;
  searchResults: SearchResult[];
  searchSelected: number;
  message: string;
  lastUpdate: number;
  running: boolean;
  needRefresh: boolean;
}
