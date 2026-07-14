import { useProvider, widget } from "@weaver/sdk";

export default widget({
  name: "System Monitor",
  size: [300, 150],
  anchor: { corner: "top-left", offset: [24, 24] },
  subscribe: ["cpu", "memory"],
}, () => {
  const cpu = useProvider("cpu");
  const memory = useProvider("memory");
  return (
    <column class="w-[300px] h-[150px] p-4 gap-3 bg-[#10131b]/92 rounded-2xl">
      <text class="text-xs text-[#60a5fa] font-semibold">SYSTEM</text>
      <row class="w-[268px] justify-between items-end">
        <column class="gap-1">
          <text class="text-xs text-[#94a3b8]">CPU</text>
          <text class="text-3xl text-[#f8fafc] font-light">{cpu.percent.toFixed(1)}%</text>
        </column>
        <column class="gap-1 items-end">
          <text class="text-xs text-[#94a3b8]">MEMORY</text>
          <text class="text-xl text-[#f8fafc] font-light">{memory.usedMb} MB</text>
          <text class="text-xs text-[#94a3b8]">of {memory.totalMb} MB · {memory.percent.toFixed(1)}%</text>
        </column>
      </row>
    </column>
  );
});
