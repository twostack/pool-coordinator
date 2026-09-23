import type { ReactiveController, ReactiveControllerHost } from 'lit';
import type { FeedState, PoolFeed } from './feed';

/** Re-renders an element whenever the shared feed changes. */
export class FeedController implements ReactiveController {
  private unsubscribe: (() => void) | null = null;

  constructor(
    private readonly host: ReactiveControllerHost,
    private readonly feed: () => PoolFeed | null,
  ) {
    host.addController(this);
  }

  get state(): FeedState | null {
    return this.feed()?.state ?? null;
  }

  hostConnected(): void {
    this.resubscribe();
  }

  hostDisconnected(): void {
    this.unsubscribe?.();
    this.unsubscribe = null;
  }

  /** Called when the host is handed another feed. */
  resubscribe(): void {
    this.unsubscribe?.();
    this.unsubscribe = this.feed()?.subscribe(() => this.host.requestUpdate()) ?? null;
  }
}
