/* webpack 配置：任务窗格 + 本地开发服务器。
 * - https://localhost:4443（office-addin-dev-certs 受信证书；与 manifest 保持一致）
 * - /relay/* 与 /healthz 反向代理到本地中转服务 http://127.0.0.1:8765（含 WebSocket 升级），
 *   规避 Office 加载项 HTTPS 页面无法直连 ws://局域网IP 的 mixed-content 限制。
 */
const HtmlWebpackPlugin = require("html-webpack-plugin");
const CopyWebpackPlugin = require("copy-webpack-plugin");
const devCerts = require("office-addin-dev-certs");

module.exports = async (env, argv) => {
  // 只有开发服务器（npm start = --mode development）才需要 devServer 和它的 HTTPS 证书。
  // 生产构建（npm run build = --mode production）绝不能在这里碰 office-addin-dev-certs：
  // 证书缺失或不受信时 getHttpsServerOptions() 会弹交互式确认，在没有终端的
  // 自动化环境里会直接挂住（本机实测卡死 15 分钟，直到超时）。
  const mode = (argv && argv.mode) || "production";
  const isDev = mode === "development";
  const httpsOptions = isDev ? await devCerts.getHttpsServerOptions() : undefined;

  const config = {
    entry: "./src/taskpane/taskpane.js",
    devtool: "source-map",
    resolve: { extensions: [".js"] },
    plugins: [
      new HtmlWebpackPlugin({
        filename: "taskpane.html",
        template: "./src/taskpane/taskpane.html",
      }),
      new CopyWebpackPlugin({
        patterns: [{ from: "assets", to: "assets" }],
      }),
    ],
  };

  if (isDev) {
    config.devServer = {
      port: 4443,
      server: { type: "https", options: httpsOptions },
      headers: { "Access-Control-Allow-Origin": "*" },
      hot: true,
      proxy: [
        {
          context: ["/relay", "/healthz"],
          target: "http://127.0.0.1:8765",
          ws: true,
          pathRewrite: { "^/relay": "" },
        },
      ],
    };
  }

  return config;
};
