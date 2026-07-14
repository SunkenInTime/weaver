import { useProvider, widget } from "@weaver/sdk";

const segmentCount = 24;

export default widget({
  name: "Now Playing",
  size: [360, 142],
  anchor: { corner: "bottom-left", offset: [24, 24] },
  layer: "desktop",
  subscribe: ["media"],
}, () => {
  const media = useProvider("media");
  const progress = media.durationMs > 0 ? Math.max(0, Math.min(1, media.positionMs / media.durationMs)) : 0;
  const filled = Math.round(progress * segmentCount);
  return (
    <column class="w-[360px] h-[142px] p-4 gap-3 bg-[#10131c]/90 rounded-2xl">
      <row class="w-[328px] justify-between items-center">
        <row class="gap-2 items-center">
          <canvas
            class="w-[14px] h-[14px]"
            fps={media.playing ? 30 : 0}
            onFrame={(ctx, frame) => {
              ctx.clear();
              const pulse = media.playing ? 0.72 + Math.sin(frame.t * Math.PI * 2) * 0.18 : 0.45;
              ctx.fillCircle(7, 7, 5 * pulse, "#8b5cf6");
            }}
          />
          <text class="text-xs text-[#8b5cf6] font-semibold">NOW PLAYING</text>
        </row>
        <text class="text-xs text-[#94a3b8]">{media.playing ? "PLAYING" : "PAUSED"}</text>
      </row>
      <column class="w-[328px] gap-1">
        <text class="text-xl text-[#f8fafc] font-medium truncate">{media.title || "Nothing playing"}</text>
        <text class="text-sm text-[#94a3b8] truncate">{media.artist || media.album || (media.title ? "Unknown artist" : "Open a media app to begin")}</text>
      </column>
      <row class="w-[328px] h-[4px] gap-1">
        {Array.from({ length: segmentCount }, (_, index) => (
          index < filled
            ? <panel class="w-[9px] h-[4px] bg-[#8b5cf6] rounded-full" />
            : <panel class="w-[9px] h-[4px] bg-[#273244] rounded-full" />
        ))}
      </row>
    </column>
  );
});
