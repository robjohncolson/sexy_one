// fake-midi.js -- a standalone injectable replacement for
// navigator.requestMIDIAccess, driven by scripts/browser-check.mjs
// through window.__SXC1_FAKE_MIDI (briefs/M4-plan.md section 4).
//
// HARNESS-ONLY. This is a committed repo file so it can be reviewed and
// reused, and it must NEVER be copied into site/public or site/static --
// D22 and check-site both assert exactly that. It is loaded with CDP's
// Page.addScriptToEvaluateOnNewDocument on a freshly created target
// BEFORE the app's document exists, followed by a per-scenario preamble
// (setOutcome / addPort calls), so the app's own boot-time feature
// detection already sees the fake.
//
// The anti-vacuity instruments (the reason this file exists at all):
//   - emit(bytes[, portId]) RETURNS THE NUMBER OF HANDLERS INVOKED, and
//   - subscribedCount() reports how many ports currently have one,
// so a negative control can show that a message WAS delivered to a
// live, subscribed port and was still refused. Without them, "did not
// confirm" is indistinguishable from "nobody was listening".
//
// Input ports are held in a plain Map so .values() / .size / .forEach
// behave like a real MIDIInputMap. addPort/removePort fire the access
// object's onstatechange, exactly like real hot-plug.
(() => {
  'use strict';
  if (window.__SXC1_FAKE_MIDI) return;

  let outcome = 'grant'; // 'grant' | 'deny' | 'absent'
  const calls = [];      // every recorded {sysex} -- evidence for "permission only on explicit action" and "never sysex"
  const inputs = new Map(); // id -> fake MIDIInput

  const access = {
    inputs,
    outputs: new Map(),
    onstatechange: null,
    sysexEnabled: false,
  };

  function makePort(id, name, manufacturer) {
    return {
      id: String(id),
      name: name === undefined || name === null ? '' : String(name),
      manufacturer: manufacturer === undefined || manufacturer === null ? '' : String(manufacturer),
      type: 'input',
      state: 'connected',
      connection: 'open',
      version: '',
      onmidimessage: null,
    };
  }

  function fireStateChange(port) {
    if (typeof access.onstatechange === 'function') {
      try {
        access.onstatechange({ port, currentTarget: access, target: access });
      } catch (e) { /* a listener error must not kill the driver */ }
    }
  }

  function fakeRequestMIDIAccess(options) {
    calls.push({ sysex: Boolean(options && options.sysex) });
    if (outcome === 'deny') {
      return Promise.reject(new DOMException('SXC1 fake MIDI: permission denied', 'SecurityError'));
    }
    return Promise.resolve(access);
  }

  function installRequest() {
    Object.defineProperty(navigator, 'requestMIDIAccess', {
      value: fakeRequestMIDIAccess,
      configurable: true,
      writable: true,
    });
  }

  function installAbsent() {
    // Make the API undefined entirely: the app's isUndefined feature
    // test must see a browser with no Web MIDI at all.
    Object.defineProperty(navigator, 'requestMIDIAccess', {
      value: undefined,
      configurable: true,
      writable: true,
    });
  }

  installRequest();

  window.__SXC1_FAKE_MIDI = {
    calls,

    setOutcome(o) {
      if (o !== 'grant' && o !== 'deny' && o !== 'absent') {
        throw new Error(`fake-midi: unknown outcome '${o}'`);
      }
      outcome = o;
      if (o === 'absent') installAbsent();
      else installRequest();
      return outcome;
    },

    addPort(id, name, manufacturer) {
      const port = makePort(id, name, manufacturer);
      inputs.set(port.id, port);
      fireStateChange(port);
      return port.id;
    },

    removePort(id) {
      const port = inputs.get(String(id));
      if (!port) return false;
      port.state = 'disconnected';
      port.connection = 'closed';
      inputs.delete(String(id));
      fireStateChange(port);
      return true;
    },

    // Deliver one message to every subscribed port (or only `portId`
    // when given). Returns the number of handlers invoked.
    emit(bytes, portId) {
      const data = Uint8Array.from(bytes);
      let invoked = 0;
      for (const port of inputs.values()) {
        if (portId !== undefined && port.id !== String(portId)) continue;
        if (typeof port.onmidimessage === 'function') {
          port.onmidimessage({ data, currentTarget: port, target: port });
          invoked += 1;
        }
      }
      return invoked;
    },

    subscribedCount() {
      let n = 0;
      for (const port of inputs.values()) {
        if (typeof port.onmidimessage === 'function') n += 1;
      }
      return n;
    },

    ports() {
      return Array.from(inputs.keys());
    },
  };
})();
