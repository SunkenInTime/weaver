import { useState, widget } from "@weaver/sdk";

// Pixel-faithful static replica of noro-player (SunkenInTime/noro-player).
// Every dimension and color comes from the skin's Variables.inc.
const noop = () => {};

export default widget({
  name: "Noro Shell",
  size: [340, 356],
  anchor: { corner: "top-right", offset: [420, 32] },
}, () => {
  const [playing, setPlaying] = useState(true);
  return (
    <stack class="size-full rounded-[51px] overflow-hidden">
      <column class="size-full bg-[#1a1a1a] rounded-[51px] border border-[#000000] shadow-[0_1px_2px_0_#ffffff1a] shadow-inner p-[14px]">
        <stack class="w-full h-[188px] rounded-t-[36px] rounded-b-[4px] overflow-hidden bg-[#000000] border border-[#000000]">
          <image src="./assets/cover.jpg" fit="cover" class="size-full" />
          <image src="./assets/GridTile.png" tile class="size-full" />
          <image src="./assets/GrainTile.png" tile class="size-full opacity-20" />
          <column class="size-full pt-[22px] pr-[24px] items-end">
            <panel class="w-[10px] h-[10px] rounded-full bg-[#ff3b30]/78" />
          </column>
          <column class="size-full justify-end">
            <row class="w-full pl-[12px] pr-[2px] items-center gap-[4px]">
              <text class="w-[72px] text-[13px] text-[#ffffff] font-[Cozette-Subset]">00:06</text>
              <text class="grow text-center truncate text-[13px] tracking-wide text-[#ffffff] font-[Cozette-Subset]">LET IT GO</text>
              <text class="w-[88px] text-right text-[13px] text-[#ffffff] font-[Cozette-Subset]">03:58 AM</text>
            </row>
            <stack class="w-full h-[3px] bg-[#ffffff]/5">
              <panel class="w-[26px] h-full bg-[#ffffff]" />
            </stack>
          </column>
        </stack>

        <stack class="w-full h-[24px] mt-[10px] rounded-[3px] overflow-hidden bg-[#1a1a1a] border border-[#000000]">
          <image src="./assets/GrilleTile.png" tile class="size-full opacity-5" />
        </stack>

        <row class="w-full mt-[4px] gap-[6px]">
          <button
            onPress={noop}
            class="w-[100px] h-[100px] items-center justify-center rounded-[8.33px] rounded-bl-[37.5px] bg-[#1a1a1a] border border-[#0a0a0a] shadow-[0_1px_2px_0_#ffffff0d] shadow-inner pressed:bg-[#141414]"
          >
            <icon d="M 7 7 L 9.333 7 L 9.333 21 L 7 21 Z M 11.083 14 L 21 21 L 21 7 Z" viewBox="0 0 28 28" class="w-[28px] h-[28px] text-[#d0d0d0]" />
          </button>
          <button
            onPress={() => setPlaying((value) => !value)}
            class="w-[100px] h-[100px] items-center justify-center rounded-[8.33px] bg-[#1a1a1a] border border-[#0a0a0a] shadow-[0_1px_2px_0_#ffffff0d] shadow-inner pressed:bg-[#141414]"
          >
            {playing
              ? <icon d="M 7 5.833 L 11.667 5.833 L 11.667 22.166 L 7 22.166 Z M 16.333 5.833 L 21 5.833 L 21 22.166 L 16.333 22.166 Z" viewBox="0 0 28 28" class="w-[28px] h-[28px] text-[#d0d0d0]" />
              : <icon d="M 9.333 5.833 L 9.333 22.167 L 22.167 14 Z" viewBox="0 0 28 28" class="w-[28px] h-[28px] text-[#d0d0d0]" />}
          </button>
          <button
            onPress={noop}
            class="w-[100px] h-[100px] items-center justify-center rounded-[8.33px] rounded-br-[37.5px] bg-[#1a1a1a] border border-[#0a0a0a] shadow-[0_1px_2px_0_#ffffff0d] shadow-inner pressed:bg-[#141414]"
          >
            <icon d="M 7 21 L 16.917 14 L 7 7 Z M 18.667 7 L 21 7 L 21 21 L 18.667 21 Z" viewBox="0 0 28 28" class="w-[28px] h-[28px] text-[#d0d0d0]" />
          </button>
        </row>
      </column>
      <image src="./assets/GrainTile.png" tile class="size-full opacity-5" />
    </stack>
  );
});
