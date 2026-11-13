import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,
  globalIgnores(["node_modules/**", ".next/**", "out/**", "build/**", "next-env.d.ts"]),
  {
    rules: {
      "@typescript-eslint/no-explicit-any": "off",
      // 기존 로그인/채팅 조회 effect가 로딩 상태를 바로 갱신한다.
      // 업그레이드로 추가된 규칙이며, 호출 시점을 바꾸면 로딩 타이밍이 달라진다.
      "react-hooks/set-state-in-effect": "off",
    },
  },
]);

export default eslintConfig;
