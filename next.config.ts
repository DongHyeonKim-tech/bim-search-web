import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "standalone",
  basePath: "/search",
  images: {
    remotePatterns: [
      { protocol: "https", hostname: "hub.haeahn.com" },
      { protocol: "https", hostname: "bim-cdn.haeahn.com" },
    ],
  },
};

export default nextConfig;
