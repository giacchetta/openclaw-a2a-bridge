module.exports = {
  apps: [
    {
      name: "openclaw-gateway",
      script: "/usr/local/bin/openclaw", // Direct path to the local binary
      interpreter: "none",                     // Tells PM2 to run the binary directly, not via 'node'
      args: ["gateway", "run", "--verbose"],   // Clean array, no npx to steal your flags
      autorestart: true,
      watch: false
    },
    {
      name: "a2a-bridge",
      script: "index.js",
      autorestart: true,
      watch: false,
      env: {
        NODE_ENV: "development",
      }
    }
  ]
};