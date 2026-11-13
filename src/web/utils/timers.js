/**
 * Timers that keep running when the tab is in the background.
 *
 * Chrome throttles chained setTimeout calls in hidden tabs to at most one per second, and after
 * about five minutes to one per minute. Printing sends each label in hundreds of small chunks with
 * a short pause between them, so in a background tab a print would crawl or appear to stop.
 * Timers inside a dedicated worker are not throttled this way, so the pause is measured there and
 * the main thread is woken with a message.
 */

let worker = null;
let nextId = 0;
const pending = new Map();

function getWorker() {
  if (worker !== null) return worker;
  try {
    const source = 'onmessage = e => setTimeout(() => postMessage(e.data.id), e.data.ms);';
    const url = URL.createObjectURL(new Blob([source], { type: 'text/javascript' }));
    worker = new Worker(url);
    URL.revokeObjectURL(url);
    worker.onmessage = (e) => {
      const resolve = pending.get(e.data);
      pending.delete(e.data);
      resolve?.();
    };
    worker.onerror = () => {
      // Fall back to ordinary timers and release anyone waiting on the worker.
      worker = false;
      for (const resolve of pending.values()) resolve();
      pending.clear();
    };
  } catch {
    worker = false;
  }
  return worker;
}

/**
 * Wait `ms` milliseconds, also when the tab is hidden.
 * @param {number} ms
 * @returns {Promise<void>}
 */
export function sleep(ms) {
  const w = getWorker();
  if (!w) return new Promise(resolve => setTimeout(resolve, ms));
  return new Promise(resolve => {
    const id = ++nextId;
    pending.set(id, resolve);
    w.postMessage({ id, ms });
  });
}

/**
 * Run `job` while holding a Web Lock. Chrome does not freeze or discard a background tab that
 * holds a lock, so a long print run is not suspended halfway.
 * @param {() => Promise<T>} job
 * @returns {Promise<T>}
 * @template T
 */
export function whileHoldingPrintLock(job) {
  if (navigator.locks?.request) {
    return navigator.locks.request('phomymo-print', job);
  }
  return job();
}
