import { useEffect, useProvider, useState, widget } from "@weaver/sdk";

const barCount = 28;
const levels = Array.from({ length: barCount }, () => 0);

const colors = [
  "#8b5cf6", "#7c6df4", "#6d7fef", "#5f91e9", "#50a3df", "#45b4d2", "#3bc2c1",
] as const;

export default widget({
  name: "Visualizer",
  size: [288, 110],
  anchor: { corner: "top-left", offset: [24, 24] },
  layer: "desktop",
  subscribe: ["audio"],
}, () => {
  const audio = useProvider("audio");
  const signalActive = audio.bands.some((value) => value > 0.002);
  const [active, setActive] = useState(signalActive);
  useEffect(() => {
    if (signalActive) setActive(true);
  }, [signalActive]);
  return (
    <column class="w-[288px] h-[110px] p-3 gap-2 bg-[#10131c]/85 rounded-2xl">
      <text class="text-xs text-[#94a3b8] font-semibold">SPECTRUM</text>
      <canvas
        class="w-[264px] h-[70px]"
        fps={active ? 30 : 0}
        onFrame={(ctx, frame) => {
        ctx.clear();
        const inset = 2;
        const gap = 2.5;
        const width = (ctx.width - inset * 2 - gap * (barCount - 1)) / barCount;
        const maxHeight = ctx.height - inset * 2;
        const dt = Math.min(frame.dt || 1 / 30, 0.08);
        for (let index = 0; index < barCount; index += 1) {
          const source = index * (audio.bands.length - 1) / (barCount - 1);
          const lower = Math.floor(source);
          const blend = source - lower;
          const target = (audio.bands[lower] ?? 0) * (1 - blend) + (audio.bands[Math.min(lower + 1, audio.bands.length - 1)] ?? 0) * blend;
          const response = target > levels[index] ? 18 : 7;
          levels[index] += (target - levels[index]) * (1 - Math.exp(-response * dt));
          if (levels[index] < 0.008) continue;
          const height = Math.max(2, levels[index] * maxHeight);
          const x = inset + index * (width + gap);
          ctx.fillRoundRect(x, ctx.height - inset - height, width, height, width / 2, colors[Math.floor(index * colors.length / barCount)]);
        }
        if (!signalActive && levels.every((value) => value < 0.008)) setActive(false);
      }}
      />
    </column>
  );
});
