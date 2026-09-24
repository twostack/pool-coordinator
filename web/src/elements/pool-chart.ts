import { LitElement, css, html, unsafeCSS, type PropertyValues } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import uPlot from 'uplot';
// uPlot's stylesheet as text, adopted by this element's shadow root: a
// document stylesheet never reaches into the page's shadow trees. It is the
// library's own file, bundled, so no served string becomes style.
import uPlotCss from 'uplot/dist/uPlot.min.css?inline';
import type { Series, SeriesBucket, SeriesMetric } from '../api';
import { FeedController } from '../controller';
import type { PoolFeed } from '../feed';

const bucketSeconds: Record<SeriesBucket, number> = { hour: 3_600, day: 86_400 };

/**
 * One time series from `/api/series` as a small chart, reloaded when a
 * round is mined, which is the only time a series changes.
 */
@customElement('pool-chart')
export class PoolChart extends LitElement {
  static override styles = [
    unsafeCSS(uPlotCss),
    css`
      :host {
        display: block;
        min-inline-size: 0;
      }
      figure {
        margin: 0;
      }
      figcaption {
        margin-block-end: 0.4rem;
        font-size: 0.9rem;
      }
      .plot {
        min-block-size: 160px;
      }
      .note {
        margin: 0.25rem 0 0;
        color: var(--pool-muted);
        font-size: 0.8rem;
      }
    `,
  ];

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
    const target = this.renderRoot.querySelector<HTMLElement>('.plot');
    const points = this.series?.points ?? [];
    this.plot?.destroy();
    this.plot = null;
    if (target === null || points.length === 0) return;
    const style = getComputedStyle(this);
    const color = style.getPropertyValue('--pool-accent').trim() || '#0b6bcb';
    const grid = style.getPropertyValue('--pool-border').trim() || '#dcdfe4';
    const text = style.getPropertyValue('--pool-muted').trim() || '#5d636e';
    const axis = { stroke: text, grid: { stroke: grid, width: 1 }, ticks: { stroke: grid, width: 1 } };
    // one bucket either side, so a young pool's few points sit in a
    // readable span rather than one uPlot stretches over years
    const pad = bucketSeconds[this.series?.bucket ?? 'hour'];
    const first = points[0]?.t ?? 0;
    const last = points.at(-1)?.t ?? first;
    const width = () => Math.max(Math.floor(target.getBoundingClientRect().width), 200);
    const bars = uPlot.paths.bars?.({ size: [0.8, 24] });
    const data: uPlot.AlignedData = [points.map((p) => p.t), points.map((p) => p.value / this.scale)];
    try {
      this.plot = new uPlot(
        {
          width: width(),
          height: 160,
          // fixed, since the plot is rebuilt whenever the series changes
          scales: { x: { time: true, auto: false, range: [first - pad, last + pad] } },
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
    this.resize ??= new ResizeObserver(() => this.plot?.setSize({ width: width(), height: 160 }));
    this.resize.observe(target);
  }
}

declare global {
  interface HTMLElementTagNameMap {
    'pool-chart': PoolChart;
  }
}
