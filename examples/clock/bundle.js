"use strict";

const card = native.createNode("panel");
native.setProp(card, "padding", 14);
native.setProp(card, "radius", 18);
native.setProp(card, "background", "#11141cdb");

const content = native.createNode("column");
native.setProp(content, "gap", 1);

const timeRow = native.createNode("row");
native.setProp(timeRow, "gap", 7);

const hoursMinutes = native.createNode("text");
native.setProp(hoursMinutes, "fontScale", 2.2);
native.setProp(hoursMinutes, "fontWeight", "medium");

const seconds = native.createNode("text");
native.setProp(seconds, "fontScale", 1.05);
native.setProp(seconds, "fontWeight", "medium");
native.setProp(seconds, "opacity", 0.72);

const dateLine = native.createNode("text");
native.setProp(dateLine, "fontScale", 0.84);
native.setProp(dateLine, "opacity", 0.64);

native.appendChild(timeRow, hoursMinutes);
native.appendChild(timeRow, seconds);
native.appendChild(content, timeRow);
native.appendChild(content, dateLine);
native.appendChild(card, content);
native.setRoot(card);

function pad2(value) {
  return String(value).padStart(2, "0");
}

function tick() {
  const now = new Date();
  native.setText(hoursMinutes, pad2(now.getHours()) + ":" + pad2(now.getMinutes()));
  native.setText(seconds, ":" + pad2(now.getSeconds()));
  native.setText(dateLine, now.toLocaleDateString(undefined, {
    weekday: "short",
    month: "short",
    day: "numeric"
  }));
}

tick();
native.setInterval(1000);
native.onTimer(tick);
native.log("clock mounted");
