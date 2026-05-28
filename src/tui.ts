import { stdin, stdout } from 'node:process';
import type { AppState, Event, Mode, Quote } from './types.js';

// ANSI helpers
const ESC = '\x1b[';
const RESET = '\x1b[0m';
const RED = '\x1b[31m';
const GREEN = '\x1b[32m';
const YELLOW = '\x1b[33m';
const CYAN = '\x1b[36m';
const BOLD = '\x1b[1m';
const REVERSE = '\x1b[7m';
const DIM = '\x1b[2m';

let originalMode: Buffer | null = null;

export function init(): void {
  if (!stdin.isTTY || !stdout.isTTY) {
    throw new Error('Terminal must be a TTY');
  }
  stdin.setRawMode(true);
  stdin.setEncoding('utf-8');
  stdin.resume();

  // Hide cursor, alternate screen, clear
  stdout.write('\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H');
}

export function deinit(): void {
  // Show cursor, reset colors, normal screen
  stdout.write('\x1b[?25h\x1b[0m\x1b[?1049l');
  if (stdin.isTTY) {
    stdin.setRawMode(false);
  }
}

function writeAll(data: string): void {
  stdout.write(data);
}

export interface Size {
  rows: number;
  cols: number;
}

export function getTerminalSize(): Size {
  return stdout.isTTY
    ? { rows: stdout.rows, cols: stdout.columns }
    : { rows: 24, cols: 80 };
}

function moveCursor(row: number, col: number): void {
  writeAll(`${ESC}${row};${col}H`);
}

function clearLine(): void {
  writeAll(`${ESC}2K`);
}

function setColor(color: string): void {
  writeAll(color);
}

// ------------------------------------------------------------------
// CJK width calculation
// ------------------------------------------------------------------

function displayWidth(text: string): number {
  let width = 0;
  for (const cp of text) {
    const code = cp.codePointAt(0) ?? 0;
    if (
      (code >= 0x4e00 && code <= 0x9fff) ||
      (code >= 0x3400 && code <= 0x4dbf) ||
      (code >= 0x3000 && code <= 0x303f) ||
      (code >= 0xff01 && code <= 0xff5e) ||
      (code >= 0x2e80 && code <= 0x2fdf)
    ) {
      width += 2;
    } else {
      width += 1;
    }
  }
  return width;
}

function writePadded(text: string, width: number): void {
  const w = displayWidth(text);
  if (w > width) {
    let written = 0;
    let out = '';
    for (const ch of text) {
      const cw = displayWidth(ch);
      if (written + cw > width - 1) break;
      out += ch;
      written += cw;
    }
    writeAll(out + '…');
  } else {
    writeAll(text);
    writeAll(' '.repeat(width - w));
  }
}

function fmtPrice(price: number): string {
  return price.toFixed(2);
}

function fmtChangePct(pct: number): string {
  if (pct >= 0) return `+${pct.toFixed(2)}%`;
  return `${pct.toFixed(2)}%`;
}

function fmtChangeAmt(amt: number): string {
  if (amt >= 0) return `+${amt.toFixed(2)}`;
  return `${amt.toFixed(2)}`;
}

// ------------------------------------------------------------------
// Rendering
// ------------------------------------------------------------------

export function render(state: AppState): void {
  const { rows, cols } = getTerminalSize();

  // Move home without clearing to avoid scrollback growth
  writeAll('\x1b[H');

  // Title bar
  setColor(BOLD + CYAN);
  writeAll('  韭菜盒子 leek-tui  ─  实时行情');
  setColor(DIM);
  writeAll(`  更新: ${state.lastUpdate}`);
  writeAll('\x1b[K'); // clear to end of line
  setColor(RESET);

  // Empty line 2
  moveCursor(2, 1);
  writeAll('\x1b[K');

  // Header line
  moveCursor(3, 1);
  setColor(BOLD);
  writePadded('名称', 16);
  writePadded('代码', 12);
  writePadded('现价', 12);
  writePadded('涨跌幅', 12);
  writePadded('涨跌额', 12);
  writeAll('\x1b[K');
  setColor(RESET);

  // Separator
  moveCursor(4, 1);
  setColor(DIM);
  writeAll('─'.repeat(cols));
  setColor(RESET);

  // Too small?
  if (rows < 10 || cols < 40) {
    moveCursor(1, 1);
    writeAll('Terminal too small');
    return;
  }

  const listStartRow = 5;
  const maxListRows = rows - 8;

  if (state.portfolio.length === 0) {
    moveCursor(listStartRow, 3);
    setColor(DIM);
    writeAll('暂无关注股票/基金，按 a 添加');
    writeAll('\x1b[K');
    setColor(RESET);
    for (let r = listStartRow + 1; r < rows - 3; r++) {
      moveCursor(r, 1);
      writeAll('\x1b[K');
    }
  } else {
    const startIdx = state.selected >= maxListRows ? state.selected - maxListRows + 1 : 0;
    const endIdx = Math.min(startIdx + maxListRows, state.portfolio.length);

    let row = listStartRow;
    for (let i = startIdx; i < endIdx; i++) {
      const item = state.portfolio[i];
      moveCursor(row, 1);

      if (i === state.selected && state.mode === 'normal') {
        setColor(REVERSE);
      }

      // Find matching quote
      const quote = state.quotes.find(
        (q) => q.code === item.code && q.market === item.market
      );

      writePadded(item.name, 16);
      setColor(DIM);
      writePadded(item.code, 12);
      setColor(RESET);

      if (quote) {
        if (i === state.selected && state.mode === 'normal') {
          setColor(REVERSE);
        }
        const color = quote.changePct > 0 ? RED : quote.changePct < 0 ? GREEN : '';
        setColor(color);
        writePadded(fmtPrice(quote.price), 12);
        writePadded(fmtChangePct(quote.changePct), 12);
        writePadded(fmtChangeAmt(quote.changeAmt), 12);
      } else {
        if (i === state.selected && state.mode === 'normal') {
          setColor(REVERSE);
        }
        setColor(DIM);
        writePadded('--', 12);
        writePadded('--', 12);
        writePadded('--', 12);
      }
      writeAll('\x1b[K');
      setColor(RESET);
      row++;
    }

    // Clear remaining rows
    while (row < rows - 3) {
      moveCursor(row, 1);
      writeAll('\x1b[K');
      row++;
    }
  }

  // Search overlay
  if (state.mode === 'search') {
    const boxRow = Math.max(1, Math.floor(rows / 2) - 6);
    const boxCol = Math.max(1, Math.floor(cols / 2) - 25);
    const boxWidth = 50;

    // Top border
    moveCursor(boxRow, boxCol);
    setColor(BOLD + CYAN);
    writeAll('┌' + '─'.repeat(boxWidth - 2) + '┐');

    moveCursor(boxRow + 1, boxCol);
    writeAll('│  添加股票/基金');
    moveCursor(boxRow + 1, boxCol + boxWidth - 1);
    writeAll('│');

    moveCursor(boxRow + 2, boxCol);
    writeAll('├' + '─'.repeat(boxWidth - 2) + '┤');

    // Search input
    moveCursor(boxRow + 3, boxCol);
    writeAll('│  > ');
    setColor(RESET);
    writeAll(state.searchQuery);
    const qw = displayWidth(state.searchQuery);
    let ci = 5 + qw;
    while (ci < boxWidth - 1) {
      writeAll(' ');
      ci++;
    }
    moveCursor(boxRow + 3, boxCol + boxWidth - 1);
    setColor(BOLD + CYAN);
    writeAll('│');

    // Results area
    moveCursor(boxRow + 4, boxCol);
    writeAll('│');
    for (let i = 1; i < boxWidth - 1; i++) writeAll(' ');
    moveCursor(boxRow + 4, boxCol + boxWidth - 1);
    writeAll('│');

    const resultStartRow = boxRow + 5;
    const maxResults = 5;
    for (let r = 0; r < maxResults; r++) {
      moveCursor(resultStartRow + r, boxCol);
      if (r < state.searchResults.length) {
        const sr = state.searchResults[r];
        if (r === state.searchSelected) {
          setColor(REVERSE);
        } else {
          setColor(RESET);
        }
        writeAll('│  ');
        writePadded(sr.name, 16);
        writePadded(sr.code, 10);
        writePadded(sr.kind, 8);
        writePadded(sr.market, 6);
        const used = 3 + 16 + 10 + 8 + 6;
        for (let c = used; c < boxWidth - 1; c++) writeAll(' ');
        setColor(BOLD + CYAN);
        writeAll('│');
      } else {
        setColor(RESET);
        writeAll('│');
        for (let i = 1; i < boxWidth - 1; i++) writeAll(' ');
        setColor(BOLD + CYAN);
        writeAll('│');
      }
    }

    moveCursor(resultStartRow + maxResults, boxCol);
    writeAll('└' + '─'.repeat(boxWidth - 2) + '┘');
    setColor(RESET);
  }

  // Confirm delete overlay
  if (state.mode === 'confirm_delete' && state.portfolio.length > 0) {
    const boxRow = Math.max(1, Math.floor(rows / 2) - 2);
    const boxCol = Math.floor(cols / 2) - 20;
    moveCursor(boxRow, boxCol);
    setColor(BOLD + YELLOW);
    writeAll('┌────────────────────────────────────────┐');
    moveCursor(boxRow + 1, boxCol);
    const item = state.portfolio[state.selected];
    writeAll('│  确认删除: ');
    setColor(RESET);
    writeAll(`${item.name}(${item.code})`);
    setColor(BOLD + YELLOW);
    writeAll('?      │');
    moveCursor(boxRow + 2, boxCol);
    writeAll('│  [Y] 确认    [N] 取消                 │');
    moveCursor(boxRow + 3, boxCol);
    writeAll('└────────────────────────────────────────┘');
    setColor(RESET);
  }

  // Bottom status bar
  const statusRow = rows - 1;
  moveCursor(statusRow, 1);
  setColor(DIM);
  clearLine();
  moveCursor(statusRow, 1);
  switch (state.mode) {
    case 'normal':
      writeAll('[a]添加 [d]删除 [↑/↓]选择 [q]退出');
      break;
    case 'search':
      writeAll('[↑/↓]选择 [Enter]确认 [Esc]取消 [Backspace]删除');
      break;
    case 'confirm_delete':
      writeAll('[Y]确认 [N]取消');
      break;
  }
  setColor(RESET);

  // Message line
  if (rows >= 2) {
    moveCursor(rows - 2, 1);
    if (state.message) {
      setColor(YELLOW);
      writeAll(state.message);
      setColor(RESET);
    }
    writeAll('\x1b[K');
  }
}

// ------------------------------------------------------------------
// Input reading
// ------------------------------------------------------------------

export function readEvent(mode: Mode): Promise<Event> {
  return new Promise((resolve) => {
    const onData = (data: Buffer | string) => {
      const chunk = Buffer.isBuffer(data) ? data.toString('utf-8') : data;
      if (chunk.length === 0) {
        cleanup();
        resolve({ type: 'none' });
        return;
      }

      const c = chunk.charCodeAt(0);

      // Escape sequences
      if (c === 0x1b) {
        if (chunk.length >= 3 && chunk[1] === '[') {
          switch (chunk[2]) {
            case 'A':
              cleanup();
              resolve({ type: 'up' });
              return;
            case 'B':
              cleanup();
              resolve({ type: 'down' });
              return;
            case 'C':
            case 'D':
              cleanup();
              resolve({ type: 'none' });
              return;
          }
        }
        // ESC key
        cleanup();
        resolve({ type: 'cancel' });
        return;
      }

      // Search mode: most keys are text input
      if (mode === 'search') {
        if (c === 0x0d || c === 0x0a) {
          cleanup();
          resolve({ type: 'select' });
          return;
        }
        if (c === 0x7f || c === 0x08) {
          cleanup();
          resolve({ type: 'backspace' });
          return;
        }
        // UTF-8 multi-byte: pass the whole chunk as a character
        cleanup();
        resolve({ type: 'char', value: chunk });
        return;
      }

      // Normal / confirm_delete
      switch (c) {
        case 0x71:
        case 0x51: // q / Q
          cleanup();
          resolve({ type: 'quit' });
          return;
        case 0x61:
        case 0x41: // a / A
          cleanup();
          resolve({ type: 'add_mode' });
          return;
        case 0x64:
        case 0x44: // d / D
          cleanup();
          resolve({ type: 'delete_item' });
          return;
        case 0x6a:
        case 0x4a: // j / J
          cleanup();
          resolve({ type: 'down' });
          return;
        case 0x6b:
        case 0x4b: // k / K
          cleanup();
          resolve({ type: 'up' });
          return;
        case 0x0d:
        case 0x0a: // Enter
          cleanup();
          resolve({ type: 'select' });
          return;
        case 0x7f:
        case 0x08: // Backspace
          cleanup();
          resolve({ type: 'backspace' });
          return;
        default:
          cleanup();
          resolve({ type: 'char', value: chunk });
          return;
      }
    };

    function cleanup() {
      stdin.off('data', onData);
      if (timer) clearTimeout(timer);
    }

    let timer: ReturnType<typeof setTimeout> | null = null;
    stdin.once('data', onData);
    // timeout to allow periodic refresh even without input
    timer = setTimeout(() => {
      cleanup();
      resolve({ type: 'none' });
    }, 30);
  });
}
