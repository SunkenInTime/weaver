import { widget } from "@weaver/sdk";

export default widget({
  name: "Styling Spacing",
  size: [320, 200],
  anchor: { corner: "top-right", offset: [24, 24] },
}, () => (
  <column class="w-[320px] h-[200px] px-5 pt-4 pb-6 gap-2 bg-zinc-900 rounded-t-[36px] rounded-b-[8px] border-2 border-slate-600">
    <text class="text-lg text-slate-50 font-semibold">Styling breadth</text>
    <row class="w-full min-h-[48px] max-h-[64px] gap-2">
      <panel class="w-1/2 h-full mr-1 bg-blue-600 rounded-tl-2xl rounded-br-2xl border border-blue-300/70" />
      <panel class="w-1/2 h-full -ml-1 bg-violet-600 rounded-tr-2xl rounded-bl-2xl border-[3px] border-violet-300" />
    </row>
    <row class="w-full grow items-center justify-around flex-wrap gap-3">
      <panel class="h-[48px] aspect-square shrink-0 self-end bg-[#f59e0b] rounded-full" />
      <column class="grow-2 shrink min-w-[80px] max-w-[180px] self-center py-1">
        <text class="text-sm text-white">Directional padding</text>
        <text class="text-xs text-slate-300 truncate">Fractions, bounds, and aspect ratio</text>
      </column>
      <panel class="size-[24px] self-start bg-[#10b981] rounded-full" />
    </row>
  </column>
));
