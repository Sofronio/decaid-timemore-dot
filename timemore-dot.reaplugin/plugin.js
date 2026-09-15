function createPlugin(host) {
  const service = "0000fff0-0000-1000-8000-00805f9b34fb";
  const weightCharacteristic = "0000fff1-0000-1000-8000-00805f9b34fb";
  const commandCharacteristic = "0000fff2-0000-1000-8000-00805f9b34fb";
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

  const headerSize = 6;
  const frameOverhead = 8;
  const maxPayloadLength = 64;
  const maxBufferBytes = 256;

  function decodeBase64(data) {
    if (typeof data !== "string" || data.length % 4 !== 0) return null;
    const bytes = [];
    for (let i = 0; i < data.length; i += 4) {
      const a = alphabet.indexOf(data[i]);
      const b = alphabet.indexOf(data[i + 1]);
      const c = data[i + 2] === "=" ? 0 : alphabet.indexOf(data[i + 2]);
      const d = data[i + 3] === "=" ? 0 : alphabet.indexOf(data[i + 3]);
      if (a < 0 || b < 0 || c < 0 || d < 0) return null;
      bytes.push((a << 2) | (b >> 4));
      if (data[i + 2] !== "=") bytes.push(((b & 15) << 4) | (c >> 2));
      if (data[i + 3] !== "=") bytes.push(((c & 3) << 6) | d);
    }
    return bytes;
  }

  function crc16(bytes) {
    let crc = 0xffff;
    for (const byte of bytes) {
      crc ^= byte;
      for (let bit = 0; bit < 8; bit++) {
        crc = (crc & 1) !== 0 ? (crc >> 1) ^ 0xa001 : crc >> 1;
      }
    }
    return crc & 0xffff;
  }

  function buildFrame(opcode, cmdId, payload) {
    const body = [
      0xa5,
      0x5a,
      opcode,
      cmdId,
      (payload.length >> 8) & 0xff,
      payload.length & 0xff,
      ...payload
    ];
    const crc = crc16(body);
    return [...body, (crc >> 8) & 0xff, crc & 0xff];
  }

  const commands = {
    tare: buildFrame(0x03, 0x0d, []),
    timerStart: buildFrame(0x03, 0x02, [0x01]),
    timerStop: buildFrame(0x03, 0x02, [0x02]),
    timerReset: buildFrame(0x03, 0x02, [0x03]),
    initUnit: buildFrame(0x03, 0x06, [0x00]),
    initMode: buildFrame(0x03, 0x08, [0x01, 0x00]),
    initBattery: buildFrame(0x02, 0x05, [])
  };

  function delay(milliseconds) {
    return new Promise((resolve) => setTimeout(resolve, milliseconds));
  }

  return {
    id: "timemore-dot.reaplugin",
    onLoad() {
      return host.devices.bindDriver("timemore-dot", {
        create() {
          let active = null;
          let battery = null;

          function stop(state) {
            if (!state || state.stopped) return;
            state.stopped = true;
            clearTimeout(state.timer);
          }

          function writeCommand(state, frame) {
            return state.session.gatt.writeWithoutResponse(
              service,
              commandCharacteristic,
              btoa(String.fromCharCode(...frame))
            );
          }

          function userCommand(frame) {
            const state = active;
            if (!state || state.stopped) {
              return Promise.reject(new Error("Timemore Dot session is not connected"));
            }
            return writeCommand(state, frame);
          }

          async function handleWeight(state, payload, sample) {
            if (payload.length < 8) return false;
            // Bitwise operators yield a signed 32-bit result, so a raw weight
            // at or above 0x80000000 already arrives negative.
            const rawWeight =
              (payload[0] << 24) |
              (payload[1] << 16) |
              (payload[2] << 8) |
              payload[3];
            const timerSeconds = (payload[6] << 8) | payload[7];
            const snapshot = {weight: rawWeight / 10};
            if (battery !== null) snapshot.battery = battery;
            if (timerSeconds > 0) snapshot.timerMs = timerSeconds * 1000;
            await state.session.publish(snapshot, sample);
            return true;
          }

          function handleBattery(payload) {
            if (payload.length === 0) return;
            const raw = payload.length >= 2 ? payload[1] : payload[0];
            if (raw <= 100) battery = raw;
          }

          async function handleFrame(state, frame, sample) {
            const opcode = frame[2];
            const cmdId = frame[3];
            if (opcode === 0x03) return false;
            const payload = frame.slice(headerSize, frame.length - 2);
            if (cmdId === 0x01) return handleWeight(state, payload, sample);
            if (cmdId === 0x05) {
              handleBattery(payload);
              return false;
            }
            return false;
          }

          async function drain(state, sample) {
            let published = false;
            while (state.buffer.length >= headerSize) {
              if (state.buffer[0] !== 0xa5 || state.buffer[1] !== 0x5a) {
                state.buffer.shift();
                continue;
              }
              const payloadLength = (state.buffer[4] << 8) | state.buffer[5];
              if (payloadLength > maxPayloadLength) {
                state.buffer.shift();
                continue;
              }
              const total = payloadLength + frameOverhead;
              if (state.buffer.length < total) return published;
              const frame = state.buffer.slice(0, total);
              state.buffer.splice(0, total);
              // Notification frames carry a fixed 00 00 tail: the firmware does
              // not compute a CRC on its notify path, so magic and length are
              // the only framing guarantees available here.
              if (await handleFrame(state, frame, sample)) published = true;
            }
            return published;
          }

          async function init(state) {
            await delay(500);
            await writeCommand(state, commands.initUnit).catch(() => {});
            await delay(200);
            await writeCommand(state, commands.initMode).catch(() => {});
            await delay(100);
            await writeCommand(state, commands.initBattery).catch(() => {});
          }

          function watchPackets(state, fail) {
            clearTimeout(state.timer);
            state.timer = setTimeout(() => {
              stop(state);
              fail(new Error("Timemore Dot protocol silence"));
              state.session.reportDisconnected().catch(() => {});
            }, 2000);
          }

          return {
            async connect(session) {
              const state = {session, stopped: false, timer: null, buffer: []};
              active = state;
              battery = null;
              let ready;
              let failed;
              let settled = false;
              const firstWeight = new Promise((resolve, reject) => {
                ready = resolve;
                failed = reject;
              });
              firstWeight.catch(() => {});
              function succeed() {
                if (!settled) {
                  settled = true;
                  ready();
                }
              }
              function fail(error) {
                if (!settled) {
                  settled = true;
                  failed(error);
                }
              }
              async function accept(data, sample) {
                if (state.stopped) return;
                const bytes = decodeBase64(data);
                if (!bytes) return;
                state.buffer.push(...bytes);
                if (state.buffer.length > maxBufferBytes) {
                  state.buffer.splice(0, state.buffer.length - maxBufferBytes);
                }
                let published = false;
                try {
                  published = await drain(state, sample);
                } catch (error) {
                  return;
                }
                if (!published || state.stopped) return;
                watchPackets(state, fail);
                succeed();
              }
              try {
                const services = await session.gatt.discoverServices();
                if (!services.includes(service)) {
                  throw new Error("Timemore Dot service unavailable");
                }
                session.gatt.onDisconnect(() => {
                  stop(state);
                  fail(new Error("Timemore Dot disconnected before readiness"));
                });
                await session.gatt.subscribe(service, weightCharacteristic, accept);
                await init(state);
                if (!state.stopped && state.timer === null) watchPackets(state, fail);
                await firstWeight;
              } catch (error) {
                stop(state);
                fail(error);
                throw error;
              }
            },
            disconnect() {
              stop(active);
            },
            tare() { return userCommand(commands.tare); },
            startTimer() { return userCommand(commands.timerStart); },
            stopTimer() { return userCommand(commands.timerStop); },
            resetTimer() { return userCommand(commands.timerReset); }
          };
        }
      });
    }
  };
}
