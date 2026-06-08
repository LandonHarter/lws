import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  env: {
    LWS_VERSION: process.env.LWS_VERSION ?? "0.0.0-dev",
  },
};

export default nextConfig;
