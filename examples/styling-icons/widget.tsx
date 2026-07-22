import { widget } from "@weaver/sdk";

export default widget({
  name: "Styling Icons",
  size: [420, 270],
  anchor: { corner: "top-right", offset: [24, 24] },
}, () => (
  <column class="w-full h-full p-5 gap-4 rounded-2xl bg-slate-950 border border-slate-700 shadow-xl">
    <row class="items-center gap-3">
      <icon name="music" class="text-3xl w-8 h-8 text-fuchsia-400" />
      <column>
        <text class="text-xl font-semibold text-white">Native icon font</text>
        <text class="text-sm text-slate-400">Lucide subset · shared text sizing and color</text>
      </column>
    </row>
    <row class="gap-3 justify-between">
      <column class="items-center gap-2 p-3 w-[88px] rounded-xl bg-slate-800 border border-slate-700 shadow-sm">
        <icon name="skip-back" class="text-2xl w-6 h-6 text-cyan-400" />
        <text class="text-xs text-slate-300">Previous</text>
      </column>
      <column class="items-center gap-2 p-3 w-[88px] rounded-xl bg-slate-800 border border-slate-700 shadow-sm">
        <icon name="play" class="text-2xl w-6 h-6 text-emerald-400" />
        <text class="text-xs text-slate-300">Play</text>
      </column>
      <column class="items-center gap-2 p-3 w-[88px] rounded-xl bg-slate-800 border border-slate-700 shadow-sm">
        <icon name="pause" class="text-2xl w-6 h-6 text-amber-400" />
        <text class="text-xs text-slate-300">Pause</text>
      </column>
      <column class="items-center gap-2 p-3 w-[88px] rounded-xl bg-slate-800 border border-slate-700 shadow-sm">
        <icon name="skip-forward" class="text-2xl w-6 h-6 text-cyan-400" />
        <text class="text-xs text-slate-300">Next</text>
      </column>
    </row>
    <row class="items-center justify-between p-3 rounded-xl bg-slate-900">
      <row class="items-center gap-4">
        <icon name="shuffle" class="text-xl w-5 h-5 text-violet-400" />
        <icon name="repeat" class="text-xl w-5 h-5 text-violet-400" />
      </row>
      <row class="items-center gap-3">
        <icon name="heart" class="text-xl w-5 h-5 text-rose-400" />
        <icon name="volume-2" class="text-xl w-5 h-5 text-slate-200" />
      </row>
    </row>
  </column>
));
