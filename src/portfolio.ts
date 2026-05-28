import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import type { Config, PortfolioItem } from './types.js';

const CONFIG_NAME = '.leek_tui.json';
const OLD_CONFIG_DIR = join(homedir(), '.config', 'leek-tui');
const OLD_CONFIG_PATH = join(OLD_CONFIG_DIR, 'portfolio.json');

function getConfigPath(): string {
  return join(homedir(), CONFIG_NAME);
}

async function migrateFromOld(): Promise<PortfolioItem[] | null> {
  try {
    const data = await readFile(OLD_CONFIG_PATH, 'utf-8');
    const parsed = JSON.parse(data) as PortfolioItem[];
    return parsed.map((item) => ({
      market: String(item.market),
      code: String(item.code),
      name: String(item.name),
    }));
  } catch {
    return null;
  }
}

export async function load(): Promise<Config> {
  const path = getConfigPath();
  try {
    const data = await readFile(path, 'utf-8');
    const parsed = JSON.parse(data) as Partial<Config>;
    const portfolio = Array.isArray(parsed.portfolio)
      ? parsed.portfolio.map((item) => ({
          market: String(item.market),
          code: String(item.code),
          name: String(item.name),
        }))
      : [];
    return {
      portfolio,
      refreshInterval: Math.max(3, Math.min(60, Number(parsed.refreshInterval) || 5)),
    };
  } catch (e: any) {
    if (e?.code === 'ENOENT') {
      const migrated = await migrateFromOld();
      if (migrated) {
        return { portfolio: migrated, refreshInterval: 5 };
      }
      return { portfolio: [], refreshInterval: 5 };
    }
    throw e;
  }
}

export async function save(config: Config): Promise<void> {
  const path = getConfigPath();
  const payload: Config = {
    portfolio: config.portfolio,
    refreshInterval: config.refreshInterval,
  };
  await writeFile(path, JSON.stringify(payload, null, 2) + '\n', 'utf-8');
}
