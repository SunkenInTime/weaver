import { useState, widget } from "@weaver/sdk";

// Capture smoke fixture: a progress fill whose width is a number-typed
// template hole, `w-[${px}px]`. weaver check validates the utility statically;
// the runtime class compiler validates the number on every change. Three
// clicks on "Log" move the fill from 0 to 42 logical pixels.
export default widget({ name: "Class Hole", size: [200, 72] }, () => {
  const [sessions, setSessions] = useState(0);
  return (
    <column class="p-3 gap-2 bg-[#11141c]">
      <row class="w-full h-[8px] rounded-full bg-[#ffffff]/10">
        <stack class={`w-[${sessions * 14}px] h-full rounded-full bg-[#5eead4]`} />
      </row>
      <button accessibilityLabel="Log" class="h-[24px] rounded-[6px] bg-[#5eead4]" onPress={() => setSessions((count) => count + 1)}>
        <text class="text-[11px]">Log</text>
      </button>
    </column>
  );
});
