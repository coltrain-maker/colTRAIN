function learningTimer(client) {
  let assignment = null, running = null, lastInteraction = Date.now(), closed = false, chain = Promise.resolve();
  const events = new AbortController();
  const send = (id, active) => {
    chain = chain.then(() => client.rpc("record_training_activity", { assignment: id, active })).catch(() => {
    });
  };
  function tick() {
    const next = !closed && !document.hidden && Date.now() - lastInteraction < 9e4 ? assignment : null;
    if (running && running !== next) send(running, false);
    if (next) send(next, true);
    running = next;
  }
  for (const type of ["pointerdown", "keydown", "scroll", "touchstart"]) document.addEventListener(type, () => {
    lastInteraction = Date.now();
  }, { passive: true, capture: true, signal: events.signal });
  document.addEventListener("visibilitychange", tick, { signal: events.signal });
  const interval = setInterval(tick, 15e3);
  return { set(id) {
    if (assignment === id) return;
    assignment = id;
    lastInteraction = Date.now();
    tick();
  }, close() {
    closed = true;
    tick();
    clearInterval(interval);
    events.abort();
  } };
}
export {
  learningTimer
};
