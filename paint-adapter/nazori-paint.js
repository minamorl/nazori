/**
 * nazori -> paint adapter.
 *
 * Turns the daemon's WebSocket records into synthetic PointerEvents dispatched
 * at paint's own canvas, so the samples travel paint's real input path --
 * palm rejection, coordinate transform, stroke batching -- rather than a
 * private back door that would test something other than what ships.
 *
 * paint is not modified. The one thing that has to be worked around is
 * setPointerCapture: the browser rejects a pointerId it never created, and the
 * exception would abort paint's pointerdown handler. The adapter neutralises
 * that call for its own pointerId only, and restores the originals on stop().
 */

const MAGIC = 0xa7;
const VERSION = 1;
const RECORD_BYTES = 40;
const HELLO_BYTES = 16;
const HELLO_KIND = 0x80;

const KIND = {
  PROXIMITY_OUT: 0,
  PROXIMITY_IN: 1,
  HOVER: 2,
  DOWN: 3,
  MOVE: 4,
  UP: 5,
  CANCEL: 6,
};

const POINTER_ID = 4242;

function decode(view) {
  if (view.byteLength < RECORD_BYTES) return null;
  if (view.getUint8(0) !== MAGIC || view.getUint8(1) !== VERSION) return null;
  return {
    kind: view.getUint8(2),
    flags: view.getUint8(3),
    seq: view.getUint32(4, true),
    x: view.getFloat32(16, true),
    y: view.getFloat32(20, true),
    pressure: view.getFloat32(24, true),
    tiltX: view.getFloat32(28, true),
    tiltY: view.getFloat32(32, true),
    twist: view.getFloat32(36, true),
  };
}

function decodeHello(view) {
  if (view.byteLength < HELLO_BYTES) return null;
  if (view.getUint8(0) !== MAGIC || view.getUint8(1) !== VERSION) return null;
  if (view.getUint8(2) !== HELLO_KIND) return null;
  return { width: view.getFloat32(4, true), height: view.getFloat32(8, true) };
}

export function connect(options = {}) {
  const {
    url = "ws://127.0.0.1:40119",
    canvas = document.getElementById("canvas"),
    fit = "contain",
    onStatus = () => {},
  } = options;

  if (!canvas) throw new Error("nazori: canvas が見つかりません");

  // The device letterboxes its active area to the Mac display's aspect, so the
  // normalized square we receive already has that shape. "contain" reproduces
  // it inside the canvas; "stretch" fills the canvas and accepts the skew.
  let sourceAspect = null;

  const originalCapture = canvas.setPointerCapture.bind(canvas);
  const originalRelease = canvas.releasePointerCapture.bind(canvas);
  canvas.setPointerCapture = (id) => {
    if (id === POINTER_ID) return;
    return originalCapture(id);
  };
  canvas.releasePointerCapture = (id) => {
    if (id === POINTER_ID) return;
    return originalRelease(id);
  };

  let down = false;
  let stopped = false;
  let socket = null;
  let retry = null;

  function toClient(nx, ny) {
    const rect = canvas.getBoundingClientRect();
    if (fit === "stretch" || !sourceAspect) {
      return { x: rect.left + nx * rect.width, y: rect.top + ny * rect.height };
    }
    let w = rect.width;
    let h = w / sourceAspect;
    if (h > rect.height) {
      h = rect.height;
      w = h * sourceAspect;
    }
    const ox = rect.left + (rect.width - w) / 2;
    const oy = rect.top + (rect.height - h) / 2;
    return { x: ox + nx * w, y: oy + ny * h };
  }

  function dispatch(type, rec, buttons) {
    const { x, y } = toClient(rec.x, rec.y);
    const ev = new PointerEvent(type, {
      bubbles: true,
      cancelable: true,
      composed: true,
      pointerId: POINTER_ID,
      pointerType: "pen",
      isPrimary: true,
      button: type === "pointerdown" || type === "pointerup" ? 0 : -1,
      buttons,
      clientX: x,
      clientY: y,
      // paint reads pressure 0 as "unknown" and substitutes 0.5, so a real
      // zero-pressure contact is nudged just above it.
      pressure: buttons ? Math.max(rec.pressure, 0.0001) : 0,
      tiltX: rec.tiltX,
      tiltY: rec.tiltY,
      twist: rec.twist,
      width: 1,
      height: 1,
    });
    canvas.dispatchEvent(ev);
  }

  function handle(rec) {
    switch (rec.kind) {
      case KIND.DOWN:
        down = true;
        dispatch("pointerdown", rec, 1);
        break;
      case KIND.MOVE:
        if (down) dispatch("pointermove", rec, 1);
        break;
      case KIND.UP:
        if (down) dispatch("pointerup", rec, 0);
        down = false;
        break;
      case KIND.CANCEL:
        if (down) dispatch("pointercancel", rec, 0);
        down = false;
        break;
      case KIND.HOVER:
        if (!down) dispatch("pointermove", rec, 0);
        break;
      case KIND.PROXIMITY_OUT:
        // A lost UP would otherwise leave paint drawing forever.
        if (down) {
          dispatch("pointerup", rec, 0);
          down = false;
        }
        break;
      default:
        break;
    }
  }

  function open() {
    if (stopped) return;
    socket = new WebSocket(url);
    socket.binaryType = "arraybuffer";
    socket.onopen = () => onStatus("nazori: 接続しました");
    socket.onclose = () => {
      onStatus("nazori: 切断されました");
      if (down) {
        down = false;
        onStatus("nazori: 途中で切れたのでストロークを閉じました");
      }
      if (!stopped) retry = setTimeout(open, 1000);
    };
    socket.onerror = () => onStatus("nazori: 接続できません");
    socket.onmessage = (e) => {
      const view = new DataView(e.data);
      if (view.byteLength === HELLO_BYTES) {
        const hello = decodeHello(view);
        if (hello) {
          sourceAspect = hello.width / hello.height;
          onStatus(`nazori: 送り元 ${hello.width}x${hello.height}`);
        }
        return;
      }
      for (let off = 0; off + RECORD_BYTES <= view.byteLength; off += RECORD_BYTES) {
        const rec = decode(new DataView(e.data, off, RECORD_BYTES));
        if (rec) handle(rec);
      }
    };
  }

  open();

  return function stop() {
    stopped = true;
    if (retry) clearTimeout(retry);
    if (socket) socket.close();
    canvas.setPointerCapture = originalCapture;
    canvas.releasePointerCapture = originalRelease;
  };
}

// Loading this file as a plain <script type="module"> is enough to start it.
if (typeof window !== "undefined" && !window.__nazoriStop) {
  window.__nazoriStop = connect({ onStatus: (m) => console.log(m) });
}
