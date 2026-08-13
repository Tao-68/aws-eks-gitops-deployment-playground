const http = require("http");
const os = require("os");

const PORT = process.env.PORT || 3000;

const server = http.createServer((req, res) => {
  if (req.url === "/healthz") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ status: "ok" }));
    return;
  }

  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(
    JSON.stringify({
      message: "Hello from gitops-portfolio",
      hostname: os.hostname(),
    })
  );
});

server.listen(PORT, () => {
  console.log(`Listening on port ${PORT}`);
});
