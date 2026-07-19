function trim(value) {
  return String(value ?? "").trim();
}

export function parseAttrs(attrStr = "") {
  const attrs = {};
  const regex = /([\w:_-]+)\s*=\s*"([^"]*)"/g;
  let match;
  while ((match = regex.exec(attrStr))) attrs[match[1]] = match[2];
  return attrs;
}

function gcdBigInt(a, b) {
  let x = a < 0n ? -a : a;
  let y = b < 0n ? -b : b;
  while (y !== 0n) {
    const t = x % y;
    x = y;
    y = t;
  }
  return x || 1n;
}

export function parseTimeValue(value) {
  const raw = trim(value).replace(/s$/, "");
  if (!raw) return null;
  if (raw.includes("/")) {
    const [num, den] = raw.split("/");
    if (!num || !den) return null;
    return { num: BigInt(num), den: BigInt(den) };
  }
  if (raw.includes(".")) return floatToTime(Number(raw));
  return { num: BigInt(raw), den: 1n };
}

export function addTime(a, b) {
  return {
    num: a.num * b.den + b.num * a.den,
    den: a.den * b.den,
  };
}

export function subTime(a, b) {
  return {
    num: a.num * b.den - b.num * a.den,
    den: a.den * b.den,
  };
}

export function mulTime(a, b) {
  return {
    num: a.num * b.num,
    den: a.den * b.den,
  };
}

export function divTime(a, b) {
  return {
    num: a.num * b.den,
    den: a.den * b.num,
  };
}

export function compareTime(a, b) {
  const diff = subTime(a, b);
  if (diff.num < 0n) return -1;
  if (diff.num > 0n) return 1;
  return 0;
}

export function formatTimeValue(value) {
  if (!value) return "";
  const sign = value.num < 0n ? -1n : 1n;
  const absNum = value.num < 0n ? -value.num : value.num;
  const gcd = gcdBigInt(absNum, value.den);
  const num = (sign < 0n ? -absNum : absNum) / gcd;
  const den = value.den / gcd;
  if (den === 1n) return `${num}s`;
  return `${num}/${den}s`;
}

export function timeToFloat(value) {
  if (!value) return NaN;
  return Number(value.num) / Number(value.den);
}

export function floatToTime(value, den = 1000000000n) {
  if (!Number.isFinite(value)) return null;
  const num = BigInt(Math.round(value * Number(den)));
  return { num, den };
}

export function parseTimeMapXML(xml = "") {
  const match = xml.match(/<timeMap\b([^>]*)>([\s\S]*?)<\/timeMap>/);
  if (!match) return [];
  const timeMapAttrs = parseAttrs(match[1] ?? "");
  const points = [];
  for (const point of match[2].matchAll(/<timept\b([^>]*)\/>/g)) {
    const attrs = parseAttrs(point[1] ?? "");
    const time = parseTimeValue(attrs.time || "");
    const value = parseTimeValue(attrs.value || "");
    if (!time || !value) continue;
    const inTime = parseTimeValue(attrs.inTime || "");
    const outTime = parseTimeValue(attrs.outTime || "");
    points.push({ time, value, interp: attrs.interp || "smooth2", inTime, outTime });
  }
  points._attrs = timeMapAttrs;
  return points;
}

export function buildSmooth2Segments(points) {
  if (!points || points.length < 2) return [];
  const segments = [];
  const transitions = [];
  for (let i = 1; i < points.length - 1; i += 1) {
    const pt = points[i];
    if (!pt.inTime && !pt.outTime) continue;
    const prev = points[i - 1];
    const next = points[i + 1];
    const leftSlope = divTime(subTime(pt.value, prev.value), subTime(pt.time, prev.time));
    const rightSlope = divTime(subTime(next.value, pt.value), subTime(next.time, pt.time));
    const inTime = pt.inTime || { num: 0n, den: 1n };
    const outTime = pt.outTime || { num: 0n, den: 1n };
    const startTime = subTime(pt.time, inTime);
    const endTime = addTime(pt.time, outTime);
    const startValue = subTime(pt.value, mulTime(leftSlope, inTime));
    const endValue = addTime(pt.value, mulTime(rightSlope, outTime));
    transitions.push({ startTime, endTime, startValue, endValue, leftSlope, rightSlope });
  }
  let currentTime = points[0].time;
  let currentValue = points[0].value;
  for (const tr of transitions) {
    if (compareTime(tr.startTime, currentTime) > 0) {
      segments.push({
        kind: "linear",
        startTime: currentTime,
        endTime: tr.startTime,
        startValue: currentValue,
        endValue: tr.startValue,
      });
    }
    segments.push({
      kind: "ramp",
      startTime: tr.startTime,
      endTime: tr.endTime,
      startValue: tr.startValue,
      endValue: tr.endValue,
      leftSlope: tr.leftSlope,
      rightSlope: tr.rightSlope,
    });
    currentTime = tr.endTime;
    currentValue = tr.endValue;
  }
  const last = points[points.length - 1];
  if (compareTime(last.time, currentTime) > 0) {
    segments.push({
      kind: "linear",
      startTime: currentTime,
      endTime: last.time,
      startValue: currentValue,
      endValue: last.value,
    });
  }
  return segments;
}

function interpolateRampSegment(seg, t) {
  const dt = timeToFloat(subTime(seg.endTime, seg.startTime));
  if (!Number.isFinite(dt) || dt === 0) return seg.startValue;
  const u = timeToFloat(divTime(subTime(t, seg.startTime), subTime(seg.endTime, seg.startTime)));
  const y0 = timeToFloat(seg.startValue);
  const y1 = timeToFloat(seg.endValue);
  const m0 = timeToFloat(seg.leftSlope);
  const m1 = timeToFloat(seg.rightSlope);
  const h00 = 2 * u ** 3 - 3 * u ** 2 + 1;
  const h10 = u ** 3 - 2 * u ** 2 + u;
  const h01 = -2 * u ** 3 + 3 * u ** 2;
  const h11 = u ** 3 - u ** 2;
  const y = h00 * y0 + h10 * dt * m0 + h01 * y1 + h11 * dt * m1;
  return floatToTime(y);
}

export function interpolateTimeMap(points, t) {
  if (!points || points.length < 2 || !t) return null;
  if ((points || []).some((pt) => pt.inTime || pt.outTime)) {
    const segments = buildSmooth2Segments(points);
    for (const seg of segments) {
      if (compareTime(t, seg.startTime) < 0 || compareTime(t, seg.endTime) > 0) continue;
      if (seg.kind === "linear") {
        const ratio = divTime(subTime(t, seg.startTime), subTime(seg.endTime, seg.startTime));
        return addTime(seg.startValue, mulTime(subTime(seg.endValue, seg.startValue), ratio));
      }
      return interpolateRampSegment(seg, t);
    }
  }
  for (let i = 0; i < points.length - 1; i += 1) {
    const a = points[i];
    const b = points[i + 1];
    if (compareTime(t, a.time) < 0 || compareTime(t, b.time) > 0) continue;
    if (compareTime(a.time, b.time) === 0) return a.value;
    const smooth = (a.interp || b.interp) === "smooth2" && (a.outTime || b.inTime);
    if (!smooth) {
      const ratio = divTime(subTime(t, a.time), subTime(b.time, a.time));
      return addTime(a.value, mulTime(subTime(b.value, a.value), ratio));
    }
    const x0 = timeToFloat(a.time);
    const x1 = timeToFloat(addTime(a.time, a.outTime || { num: 0n, den: 1n }));
    const x2 = timeToFloat(subTime(b.time, b.inTime || { num: 0n, den: 1n }));
    const x3 = timeToFloat(b.time);
    const y0 = timeToFloat(a.value);
    const y1 = y0;
    const y2 = timeToFloat(b.value);
    const y3 = y2;
    const targetX = timeToFloat(t);
    const bez = (p0, p1, p2, p3, u) =>
      ((1 - u) ** 3) * p0 +
      3 * ((1 - u) ** 2) * u * p1 +
      3 * (1 - u) * (u ** 2) * p2 +
      (u ** 3) * p3;
    let lo = 0;
    let hi = 1;
    for (let iter = 0; iter < 50; iter += 1) {
      const mid = (lo + hi) / 2;
      const x = bez(x0, x1, x2, x3, mid);
      if (x < targetX) lo = mid;
      else hi = mid;
    }
    const u = (lo + hi) / 2;
    return floatToTime(bez(y0, y1, y2, y3, u));
  }
  return null;
}
