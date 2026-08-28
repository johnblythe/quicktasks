const raycast = require("@raycast/eslint-config");

module.exports = [
  { ignores: ["raycast-env.d.ts", "eslint.config.js", "dist/**", "node_modules/**"] },
  ...raycast,
];
