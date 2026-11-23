exports.handler = async (event) => {
  console.log(JSON.stringify({ handler: "example-fn", event }));
  return { ok: true };
};
