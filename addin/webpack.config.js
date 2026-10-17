/* webpack 配置：任务窗格 + 本地开发服务器。
 * - https://localhost:3000（office-addin-dev-certs 受信证书）
 * - /relay/* 反向代理到本地中转服务 http://127.0.0.1:8765（含 WebSocket 升级），
 *   规避 Office 加载项 HTTPS 页面无法直连 ws://局域网IP 的 mixed-content 限制。
 */
const HtmlWebpackPlugin = require("html-webpack-plugin");
const CopyWebpackPlugin = require("copy-webpack-plugin");
const devCerts = require("office-addin-dev-certs");

module.exports = async () => {
  const httpsOptions = await devCerts.getHttpsServerOptions();

  return {
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
    devServer: {
      port: 3000,
      server: { type: "https", options: httpsOptions },
      headers: { "Access-Control-Allow-Origin": "*" },
      hot: true,
      proxy: [
        {
          context: ["/relay"],
          target: "http://127.0.0.1:8765",
          ws: true,
          pathRewrite: { "^/relay": "" },
        },
      ],
    },
  };
};
