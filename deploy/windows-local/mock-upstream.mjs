// 临时 mock OpenAI 上游：验证 proxy 转发链路用
import http from "node:http";
const server = http.createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({
      id: "chatcmpl-mock-001",
      object: "chat.completion",
      created: Math.floor(Date.now() / 1000),
      model: "mock-model",
      choices: [{
        index: 0,
        message: { role: "assistant", content: "MOCK-UPSTREAM-OK: proxy forwarding verified" },
        finish_reason: "stop",
      }],
      usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
    }));
  });
});
server.listen(18099, "127.0.0.1", () => console.log("mock upstream on 18099"));
