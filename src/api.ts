import type { PortfolioItem, Quote, SearchResult } from './types.js';

// ------------------------------------------------------------------
// HTTP helpers
// ------------------------------------------------------------------

const USER_AGENTS = [
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:133.0) Gecko/20100101 Firefox/133.0',
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15',
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0',
];

function randUA(): string {
  return USER_AGENTS[Math.floor(Math.random() * USER_AGENTS.length)];
}

async function fetchWithTimeout(url: string, timeoutMs = 5000): Promise<string> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const res = await fetch(url, {
      signal: controller.signal,
      headers: {
        'User-Agent': randUA(),
        Accept: '*/*',
        Connection: 'keep-alive',
      },
    });
    clearTimeout(timer);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.text();
  } catch (e) {
    clearTimeout(timer);
    throw e;
  }
}

// ------------------------------------------------------------------
// URL encoding (RFC3986 unreserved)
// ------------------------------------------------------------------

function isUrlSafe(c: string): boolean {
  return /^[a-zA-Z0-9_.~-]$/.test(c);
}

function urlEncode(input: string): string {
  let out = '';
  for (const c of input) {
    if (isUrlSafe(c)) {
      out += c;
    } else {
      for (const b of new TextEncoder().encode(c)) {
        out += '%' + b.toString(16).toUpperCase().padStart(2, '0');
      }
    }
  }
  return out;
}

// ------------------------------------------------------------------
// Unicode escape decoder (\uXXXX)
// ------------------------------------------------------------------

function decodeUnicodeEscapes(input: string): string {
  return input.replace(/\\u([0-9a-fA-F]{4})/g, (_, hex) => {
    return String.fromCodePoint(parseInt(hex, 16));
  });
}

// ------------------------------------------------------------------
// Search (Tencent smartbox)
// ------------------------------------------------------------------

export async function search(query: string): Promise<SearchResult[]> {
  const encoded = urlEncode(query);
  const url = `https://smartbox.gtimg.cn/s3/?q=${encoded}&t=all`;

  const body = await fetchWithTimeout(url, 5000);

  const prefix = 'v_hint="';
  const start = body.indexOf(prefix);
  if (start === -1) return [];

  const end = body.indexOf('";', start + prefix.length);
  const content = body.slice(start + prefix.length, end === -1 ? undefined : end);
  if (!content) return [];

  const results: SearchResult[] = [];
  for (const item of content.split('^')) {
    if (!item) continue;
    const parts = item.split('~');
    if (parts.length < 5) continue;
    const [market, code, rawName, pinyin, kind] = parts;
    results.push({
      market,
      code,
      name: decodeUnicodeEscapes(rawName),
      pinyin,
      kind,
    });
  }
  return results;
}

// ------------------------------------------------------------------
// Quote fetching (EastMoney)
// ------------------------------------------------------------------

function toEastMoneyMarket(market: string): string | null {
  if (market === 'sh') return '1';
  if (market === 'sz') return '0';
  if (market === 'hk') return '116';
  if (market === 'us') return '105';
  return null;
}

interface Categorized {
  emIds: string;
  emItems: PortfolioItem[];
  jjCodes: string;
  jjItems: PortfolioItem[];
}

function categorizeItems(items: PortfolioItem[]): Categorized {
  const emParts: string[] = [];
  const emItems: PortfolioItem[] = [];
  const jjParts: string[] = [];
  const jjItems: PortfolioItem[] = [];

  for (const item of items) {
    if (item.market === 'jj') {
      if (jjParts.length) jjParts.push(',');
      jjParts.push(item.code);
      jjItems.push(item);
    } else {
      const prefix = toEastMoneyMarket(item.market);
      if (prefix) {
        if (emParts.length) emParts.push(',');
        emParts.push(`${prefix}.${item.code}`);
        emItems.push(item);
      }
    }
  }

  return {
    emIds: emParts.join(''),
    emItems,
    jjCodes: jjParts.join(''),
    jjItems,
  };
}

function parseEastMoney(body: string, emItems: PortfolioItem[]): Quote[] {
  const quotes: Quote[] = [];
  try {
    const data = JSON.parse(body);
    const diff = data?.data?.diff;
    if (!Array.isArray(diff)) return quotes;

    for (const item of diff) {
      const code = item.f12;
      const rawName = item.f14;
      const price = item.f2;
      const changePct = item.f3;
      const changeAmt = item.f4;
      if (!code) continue;

      // find original market from code
      const orig = emItems.find((o) => o.code === String(code));
      const marketStr = orig?.market ?? 'sh';

      quotes.push({
        market: marketStr,
        code: String(code),
        name: String(rawName ?? ''),
        price: typeof price === 'number' ? price : parseFloat(price) || 0,
        changePct: typeof changePct === 'number' ? changePct : parseFloat(changePct) || 0,
        changeAmt: typeof changeAmt === 'number' ? changeAmt : parseFloat(changeAmt) || 0,
      });
    }
  } catch {
    // ignore parse errors
  }
  return quotes;
}

function parseFund(body: string): Quote[] {
  const quotes: Quote[] = [];
  try {
    const data = JSON.parse(body);
    const datas = data?.Datas;
    if (!Array.isArray(datas)) return quotes;

    for (const item of datas) {
      const fcode = item.FCODE;
      const shortname = item.SHORTNAME;
      const nav = item.NAV;
      const navchgrt = item.NAVCHGRT;
      if (!fcode) continue;

      const navF = parseFloat(nav) || 0;
      const chgF = parseFloat(navchgrt) || 0;
      const chgAmt = navF * chgF / 100;

      quotes.push({
        market: 'jj',
        code: String(fcode),
        name: String(shortname ?? ''),
        price: navF,
        changePct: chgF,
        changeAmt: chgAmt,
      });
    }
  } catch {
    // ignore parse errors
  }
  return quotes;
}

export async function fetchQuotes(items: PortfolioItem[]): Promise<Quote[]> {
  if (items.length === 0) return [];

  const cat = categorizeItems(items);

  const urls: { type: 'em' | 'jj'; url: string }[] = [];
  if (cat.emIds) {
    urls.push({
      type: 'em',
      url: `https://push2.eastmoney.com/api/qt/ulist.np/get?fltt=2&invt=2&fields=f12,f13,f14,f2,f3,f4&secids=${cat.emIds}`,
    });
  }
  if (cat.jjCodes) {
    urls.push({
      type: 'jj',
      url: `https://fundmobapi.eastmoney.com/FundMNewApi/FundMNFInfo?pageIndex=1&pageSize=20&appType=ttjj&product=EFund&plat=Android&deviceid=abc&Version=1&Fcodes=${cat.jjCodes}`,
    });
  }

  // parallel fetch with Promise.all
  const responses = await Promise.all(
    urls.map(async ({ type, url }) => {
      try {
        const body = await fetchWithTimeout(url, 5000);
        return { type, body, ok: true } as const;
      } catch {
        return { type, body: '', ok: false } as const;
      }
    })
  );

  const quotes: Quote[] = [];
  for (const res of responses) {
    if (!res.ok) continue;
    if (res.type === 'em') {
      quotes.push(...parseEastMoney(res.body, cat.emItems));
    } else {
      quotes.push(...parseFund(res.body));
    }
  }

  return quotes;
}
