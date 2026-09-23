// Formatting for the page: every figure that may be missing becomes a dash,
// never a zero, so "no cost recorded yet" is not read as "free".

export const dash = '–';

const whole = new Intl.NumberFormat('en', { maximumFractionDigits: 0 });

export function count(n: number | null | undefined): string {
  return n === null || n === undefined ? dash : whole.format(n);
}

export function sats(n: number | null | undefined): string {
  return n === null || n === undefined ? dash : `${whole.format(Math.round(n))} sat`;
}

/** An amount in BSV from satoshis, without trailing zeros past the unit. */
export function bsv(n: number | null | undefined): string {
  if (n === null || n === undefined) return dash;
  const s = (n / 1e8).toFixed(8).replace(/0+$/, '').replace(/\.$/, '');
  return `${s} BSV`;
}

/** A span of seconds as the two largest units, such as "3 d 4 h" or "4 min 14 s". */
export function duration(seconds: number | null | undefined): string {
  if (seconds === null || seconds === undefined || !Number.isFinite(seconds) || seconds < 0) return dash;
  const units: [string, number][] = [['d', 86_400], ['h', 3_600], ['min', 60], ['s', 1]];
  let rest = Math.round(seconds);
  const parts: string[] = [];
  for (const [name, size] of units) {
    const k = Math.floor(rest / size);
    if (k > 0 || (parts.length === 0 && size === 1)) parts.push(`${k} ${name}`);
    rest -= k * size;
    if (parts.length === 2) break;
  }
  return parts.join(' ');
}

const clock = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' });
const hhmm = new Intl.DateTimeFormat(undefined, { timeStyle: 'short' });

/** An epoch-seconds time as the viewer's local date and time. */
export function when(epochSeconds: number | null | undefined): string {
  return epochSeconds === null || epochSeconds === undefined ? dash : clock.format(epochSeconds * 1_000);
}

export function timeOfDay(epochMs: number): string {
  return hhmm.format(epochMs);
}

/** A countdown to an epoch-seconds deadline, as "m:ss", or "closing" once it has passed. */
export function countdown(deadlineSeconds: number, nowMs: number): string {
  const left = Math.ceil(deadlineSeconds - nowMs / 1_000);
  if (left <= 0) return 'closing';
  const m = Math.floor(left / 60);
  const s = left % 60;
  return `${m}:${String(s).padStart(2, '0')}`;
}
