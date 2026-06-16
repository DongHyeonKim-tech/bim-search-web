"use client";
import { memo } from "react";

import {
  BarChart,
  Bar,
  LineChart,
  Line,
  PieChart,
  Pie,
  Cell,
  ScatterChart,
  Scatter,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
  ResponsiveContainer,
} from "recharts";

type ChartSpec = {
  type: "bar" | "line" | "pie" | "scatter";
  title: string;
  description?: string;
  xKey: string;
  yKey: string;
  seriesName?: string;
  data: Record<string, string | number>[];
};

const CHART_COLORS = [
  "#6366f1",
  "#8b5cf6",
  "#ec4899",
  "#f43f5e",
  "#f97316",
  "#eab308",
  "#22c55e",
  "#14b8a6",
  "#06b6d4",
  "#3b82f6",
  "#a855f7",
  "#10b981",
];

function getColorForXKey(
  value: string | number,
  xValues: (string | number)[]
): string {
  const index = xValues.indexOf(value);
  return CHART_COLORS[(index >= 0 ? index : 0) % CHART_COLORS.length];
}

function ChartRenderer({ spec }: { spec: ChartSpec }) {
  const {
    type,
    title,
    description,
    xKey,
    yKey,
    seriesName = yKey,
    data,
  } = spec;

  if (!data?.length) return null;

  const xValues = [...new Set(data.map((d) => d[xKey]))];

  return (
    <div
      style={{
        width: "100%",
        height: 400,
        fontFamily: "Pretendard",
        color: "#fff",
      }}
    >
      <div style={{ marginBottom: 12 }}>
        <strong>{title}</strong>
        {description && (
          <p style={{ margin: "4px 0 0", color: "#999" }}>{description}</p>
        )}
      </div>

      <ResponsiveContainer
        width="100%"
        height="100%"
      >
        {type === "bar" ? (
          <BarChart data={data}>
            <CartesianGrid strokeDasharray="3 3" />
            <XAxis
              dataKey={xKey}
              tick={{ fill: "#fff", fontSize: 12 }}
            />
            <YAxis />
            <Tooltip />
            <Legend />
            <Bar
              dataKey={yKey}
              name={seriesName}
            >
              {data.map((entry, index) => (
                <Cell
                  key={`bar-${index}`}
                  fill={getColorForXKey(entry[xKey], xValues)}
                />
              ))}
            </Bar>
          </BarChart>
        ) : type === "line" ? (
          <LineChart data={data}>
            <CartesianGrid strokeDasharray="3 3" />
            <XAxis
              dataKey={xKey}
              tick={{ fill: "#fff", fontSize: 12 }}
            />
            <YAxis />
            <Tooltip />
            <Legend />
            <Line
              dataKey={yKey}
              name={seriesName}
              stroke="#94a3b8"
              strokeWidth={2}
              dot={(props) => {
                const { cx, cy, index } = props;
                if (cx == null || cy == null || index == null) return null;
                const entry = data[index];
                return (
                  <circle
                    cx={cx}
                    cy={cy}
                    r={5}
                    fill={getColorForXKey(entry[xKey], xValues)}
                    stroke="#fff"
                    strokeWidth={1.5}
                  />
                );
              }}
              activeDot={(props) => {
                const { cx, cy, index } = props;
                if (cx == null || cy == null || index == null) return null;
                const entry = data[index];
                return (
                  <circle
                    cx={cx}
                    cy={cy}
                    r={7}
                    fill={getColorForXKey(entry[xKey], xValues)}
                    stroke="#fff"
                    strokeWidth={2}
                  />
                );
              }}
            />
          </LineChart>
        ) : type === "pie" ? (
          <PieChart>
            <Tooltip />
            <Legend />
            <Pie
              data={data}
              dataKey={yKey}
              nameKey={xKey}
              outerRadius={110}
              label
            >
              {data.map((entry, index) => (
                <Cell
                  key={`pie-${index}`}
                  fill={getColorForXKey(entry[xKey], xValues)}
                />
              ))}
            </Pie>
          </PieChart>
        ) : (
          <ScatterChart>
            <CartesianGrid strokeDasharray="3 3" />
            <XAxis
              dataKey={xKey}
              name={xKey}
            />
            <YAxis
              dataKey={yKey}
              name={yKey}
            />
            <Tooltip cursor={{ strokeDasharray: "3 3" }} />
            <Legend />
            <Scatter
              name={seriesName}
              data={data}
            >
              {data.map((entry, index) => (
                <Cell
                  key={`scatter-${index}`}
                  fill={getColorForXKey(entry[xKey], xValues)}
                />
              ))}
            </Scatter>
          </ScatterChart>
        )}
      </ResponsiveContainer>
    </div>
  );
}

export default memo(ChartRenderer, (prev, next) => prev.spec === next.spec);
