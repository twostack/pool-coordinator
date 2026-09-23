import { LitElement, html, type PropertyValues } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import uPlot from 'uplot';
import 'uplot/dist/uPlot.min.css';
import type { Series, SeriesBucket, SeriesMetric } from '../api';
import { FeedController } from '../controller';
import type { PoolFeed } from '../feed';

/**
 * One time series from `/api/series` as a small chart. It renders into its
 * own light DOM so uPlot's stylesheet applies, and reloads when a round is
 * mined, which is the only time a series changes.
 */
@customElement('pool-chart')
export class PoolChart extends LitElement {
  @property({ attribute: false }) feed: PoolFeed | null = null;
  @property() metric: SeriesMetric = 'rounds';
  @property() label = '';
  /** Divides each value for display, such as 1e8 for satoshis as BSV. */
  @property({ type: Number }) scale = 1;
  @property({ type: Boolean }) bars = false;

  @state() private series: Series | null = null;
  @state() private failed = false;

  private readonly data = new FeedController(this, () => this.feed);
  private plot: uPlot | null = null;
  private resize: ResizeObserver | null = null;
  private loadedAt: number | null = null;

  protected override createRenderRoot(): HTMLElement {
    return this;
  }

  override disconnectedCallback(): void {
    super.disconnectedCallback();
    this.resize?.disconnect();
    this.plot?.destroy();
    this.plot = null;
  }

  protected override willUpdate(changed: PropertyValues<this>): void {
    if (changed.has('feed')) this.data.resubscribe();
    const s = this.data.state;
    const tip = s?.rounds.at(-1)?.number ?? 0;
    if (this.feed !== null && s?.pool && tip !== this.loadedAt) {
      this.loadedAt = tip;
      void this.load(this.bucket());
    }
  }

  /** Hours while the pool is young, days once hours would not fit the 1,000 points served. */
  private bucket(): SeriesBucket {
    const first = this.data.state?.stats?.firstPublishedAt;
    return first != null && Date.now() / 1_000 - first > 30 * 86_400 ? 'day' : 'hour';
  }

  private async load(bucket: SeriesBucket): Promise<void> {
    const feed = this.feed;
    if (feed === null) return;
    try {
      this.series = await feed.series(this.metric, bucket);
      this.failed = false;
    } catch {
      this.failed = true;
    }
  }

  override render() {
    const empty = this.series !== null && this.series.points.length === 0;
    return html`<figure class="pool-chart">
      <figcaption>${this.label}</figcaption>
      <div class="plot" role="img" aria-label=${this.label}></div>
      ${this.failed ? html`<p class="note">not available</p>` : empty ? html`<p class="note">no rounds yet</p>` : ''}
    </figure>`;
  }

  protected override updated(changed: PropertyValues): void {
    if (!changed.has('series')) return;
    const target = this.querySelector<HTMLElement>('.plot');
    const points = this.series?.points ?? [];
    this.plot?.destroy();
    this.plot = null;
    if (target === null || points.length === 0) return;
    const style = getComputedStyle(this);
    const color = style.getPropertyValue('--pool-accent').trim() || '#0b6bcb';
    const grid = style.getPropertyValue('--pool-border').trim() || '#dcdfe4';
    const text = style.getPropertyValue('--pool-muted').trim() || '#5d636e';
    const axis = { stroke: text, grid: { stroke: grid, width: 1 }, ticks: { stroke: grid, width: 1 } };
    const bars = uPlot.paths.bars?.({ size: [0.8, 24] });
    const data: uPlot.AlignedData = [points.map((p) => p.t), points.map((p) => p.value / this.scale)];
    try {
      this.plot = new uPlot(
        {
          width: Math.max(target.clientWidth, 200),
          height: 160,
          legend: { show: false },
          cursor: { show: false },
          axes: [axis, { ...axis, size: 56 }],
          series: [
            {},
            {
              stroke: color,
              fill: `${color}33`,
              width: 2,
              ...(this.bars && bars ? { paths: bars } : {}),
            },
          ],
        },
        data,
        target,
      );
    } catch {
      // no canvas (a test DOM, or a browser that refuses it): the caption stays
      this.failed = true;
      return;
    }
    this.resize ??= new ResizeObserver(() => this.plot?.setSize({ width: Math.max(target.clientWidth, 200), height: 160 }));
    this.resize.observe(target);
  }
}

declare global {
  interface HTMLElementTagNameMap {
    'pool-chart': PoolChart;
  }
}
