import { useProvider, widget } from "@weaver/sdk";

export default widget({
  name: "Clock",
  size: [240, 110],
  anchor: { corner: "top-right", offset: [24, 24] },
  subscribe: ["time"],
}, () => {
  const time = useProvider("time");
  return (
    <column class="w-[240px] h-[110px] p-4 gap-1 bg-[#11141c]/86 rounded-2xl">
      <row class="items-baseline gap-2">
        <text class="text-3xl text-[#f8fafc] font-light">{time.hh}:{time.mm}</text>
        <text class="text-sm text-[#cbd5e1] opacity-70">:{time.ss}</text>
      </row>
      <text class="text-xs text-[#94a3b8]">{time.weekday}, {time.month} {time.day}</text>
    </column>
  );
});
