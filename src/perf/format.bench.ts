import { bench, describe } from "vitest";
import { formatCharCount, formatSize, formatTime } from "@/lib/format";

const values = Array.from({ length: 10_000 }, (_, index) => index * 100);
const dates = values.map((offset) => new Date(Date.UTC(2026, 0, 1) - offset).toISOString());

describe("Format functions: 10,000 values", () => {
  bench("absolute time", () => {
    for (const date of dates) formatTime(date);
  });

  bench("relative time", () => {
    for (const date of dates) formatTime(date, "relative");
  });

  bench("byte size", () => {
    for (const value of values) formatSize(value);
  });

  bench("character count", () => {
    for (const value of values) formatCharCount(value);
  });
});
