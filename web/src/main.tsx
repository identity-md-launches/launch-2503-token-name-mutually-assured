import React from "react";
import ReactDOM from "react-dom/client";
import { WagmiProvider } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { loadConfig } from "./config";
import { App } from "./App";
import "./style.css";
const root = ReactDOM.createRoot(document.getElementById("root")!);
root.render(
  <main className="boot">
    <h1>MAD control room</h1>
    <p>Reading the verified Ethereum deployment…</p>
  </main>,
);
loadConfig()
  .then((rt) => {
    const query = new QueryClient({
      defaultOptions: { queries: { refetchOnWindowFocus: true } },
    });
    root.render(
      <React.StrictMode>
        <WagmiProvider config={rt.wagmi}>
          <QueryClientProvider client={query}>
            <App rt={rt} />
          </QueryClientProvider>
        </WagmiProvider>
      </React.StrictMode>,
    );
  })
  .catch((error) =>
    root.render(
      <main className="boot">
        <h1>Deployment unavailable</h1>
        <p role="alert">{String(error.message)}</p>
        <button onClick={() => location.reload()}>Reload deployment</button>
      </main>,
    ),
  );
