// The coordinator's read-only API, version 1. These types are the contract
// with lib/src/api/pool_api.dart: within version 1 fields are only added, so
// a field the page does not know is ignored and a missing optional one is a
// dash. Times are epoch seconds, already rounded by the coordinator to its
// publication interval; amounts are satoshis.

export const apiVersion = 1;

/** The public stage of a round being built, as the coordinator names it. */
export type Stage = 'proving' | 'funding' | 'broadcast';

export interface LiveRound {
  number: number;
  stage: Stage;
}

/** What the pool is doing now: the `live` event and `/api/pool`'s `live`. */
export interface LiveState {
  at: number;
  assembling: boolean;
  closesBy: number | null;
  rounds: LiveRound[];
}

/** One recorded round. Rebuilt rounds have no times, durations or cost. */
export interface RoundRecord {
  number: number;
  y: string;
  round: string;
  witness: string;
  transfers: number;
  capacity: number;
  balance: number;
  cost: number | null;
  buildMs: number | null;
  provingMs: number | null;
  publishedAt: number | null;
  minedHeight: number | null;
  minedAt: number | null;
}

/** Which public explorer holds the pool's transactions; null for regtest. */
export type Explorer = 'main' | 'test';

export interface PoolSummary {
  network: string;
  explorer?: Explorer | null;
  plan: string;
  capacity: number;
  genesis: { issuance: string; witness0: string; slot0: string };
  tip: number;
  balance: number | null;
  roundDeadlineSeconds: number;
  publishIntervalSeconds: number;
  live: LiveState;
  /**
   * What a wallet needs to join the pool, or null when the operator has not
   * named it. Left unknown here: `pool-connect` checks it before showing it.
   */
  wallet?: unknown;
}

export interface RoundsPage {
  rounds: RoundRecord[];
  next: number | null;
}

export interface PoolStats {
  roundsMined: number;
  transfers: number;
  tip: number;
  medianIntervalSeconds: number | null;
  medianProvingSeconds: number | null;
  meanCost: number | null;
  firstPublishedAt: number | null;
}

export type SeriesMetric = 'rounds' | 'transfers' | 'balance' | 'cost' | 'proving';
export type SeriesBucket = 'hour' | 'day';

export interface SeriesPoint {
  t: number;
  value: number;
}

export interface Series {
  metric: SeriesMetric;
  bucket: SeriesBucket;
  points: SeriesPoint[];
}

/** A response of another version, which this page cannot read safely. */
export class VersionError extends Error {}

/**
 * Checks a parsed body's version and returns it typed. The page trusts the
 * coordinator for the shape (the proxy fronts nothing else) but not for
 * markup: every string is rendered as text by the elements.
 */
export function versioned<T>(body: unknown): T {
  if (typeof body !== 'object' || body === null || (body as { v?: unknown }).v !== apiVersion) {
    throw new VersionError(`the API answered a version other than ${apiVersion}`);
  }
  return body as T;
}

export interface RoundsQuery {
  before?: number | undefined;
  limit?: number | undefined;
}

export function roundsPath({ before, limit }: RoundsQuery = {}): string {
  const q = new URLSearchParams();
  if (before !== undefined) q.set('before', String(before));
  if (limit !== undefined) q.set('limit', String(limit));
  const s = q.toString();
  return s ? `/api/rounds?${s}` : '/api/rounds';
}

export function seriesPath(metric: SeriesMetric, bucket: SeriesBucket): string {
  return `/api/series?metric=${metric}&bucket=${bucket}`;
}
