import { widget } from "@weaver/sdk";

const barCount = 28;
const levels = Array.from({ length: barCount }, (_, index) => 0.2 + (index % 7) * 0.06);
const velocities = Array.from({ length: barCount }, (_, index) => ((index * 17) % 11 - 5) * 0.002);
let seed = 0x51f15e;

function nextNoise(): number {
  seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
  return (seed / 0xffffffff) * 2 - 1;
}

const colors = [
  "#8b5cf6", "#7c6df4", "#6d7fef", "#5f91e9", "#50a3df", "#45b4d2", "#3bc2c1",
] as const;

export default widget({
  name: "Visualizer",
  size: [288, 84],
  anchor: { corner: "top-left", offset: [24, 24] },
  layer: "desktop",
}, () => (
  <canvas
    class="w-[288px] h-[84px]"
    fps={30}
    onFrame={(ctx, frame) => {
      ctx.clear();
      ctx.fillRoundRect(0, 0, ctx.width, ctx.height, 18, "#10131cdb");
      const inset = 14;
      const gap = 2.5;
      const width = (ctx.width - inset * 2 - gap * (barCount - 1)) / barCount;
      const maxHeight = ctx.height - inset * 2;
      const step = Math.min(frame.dt || 1 / 30, 0.08) * 60;
      for (let index = 0; index < barCount; index += 1) {
        velocities[index] = Math.max(-0.035, Math.min(0.035, velocities[index] + nextNoise() * 0.004 * step));
        levels[index] += velocities[index] * step;
        if (levels[index] < 0.12 || levels[index] > 0.98) {
          levels[index] = Math.max(0.12, Math.min(0.98, levels[index]));
          velocities[index] *= -0.72;
        }
        const height = Math.max(4, levels[index] * maxHeight);
        const x = inset + index * (width + gap);
        ctx.fillRoundRect(x, ctx.height - inset - height, width, height, width / 2, colors[Math.floor(index * colors.length / barCount)]);
      }
    }}
  />
));
