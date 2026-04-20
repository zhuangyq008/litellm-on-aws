const MODEL_COLORS = {
  opus: "bg-pink-100 text-pink-800",
  sonnet: "bg-purple-100 text-purple-800",
  haiku: "bg-sky-100 text-sky-800",
  gpt: "bg-green-100 text-green-800",
  gemini: "bg-amber-100 text-amber-800",
};

function modelBadge(model) {
  const key = Object.keys(MODEL_COLORS).find((k) => model?.toLowerCase().includes(k));
  const color = MODEL_COLORS[key] || "bg-gray-100 text-gray-800";
  const label = model?.split(".").pop()?.split("-v")[0] || model;
  return <span className={`${color} px-2 py-0.5 rounded-full text-xs`}>{label}</span>;
}

function toolBadges(toolNamesStr) {
  if (!toolNamesStr) return <span className="text-gray-400">&mdash;</span>;
  try {
    const names = JSON.parse(toolNamesStr.replace(/'/g, '"'));
    return names.map((name) => (
      <span key={name} className="bg-green-50 text-green-800 px-1.5 py-0.5 rounded text-xs mr-1">{name}</span>
    ));
  } catch {
    return <span className="text-gray-400">&mdash;</span>;
  }
}

export default function ResultsTable({ results, onSelectRow, selectedId }) {
  if (!results.length) {
    return <div className="p-10 text-center text-gray-400">No results. Adjust filters and search.</div>;
  }

  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm">
        <thead>
          <tr className="bg-white border-b-2 border-gray-200 text-gray-500 font-semibold">
            <th className="px-3 py-2.5 text-left">Time</th>
            <th className="px-2 py-2.5 text-left">Model</th>
            <th className="px-2 py-2.5 text-left">Type</th>
            <th className="px-2 py-2.5 text-left">Finish</th>
            <th className="px-2 py-2.5 text-right">Tokens</th>
            <th className="px-2 py-2.5 text-left">Tools</th>
            <th className="px-2 py-2.5 text-left">User Message</th>
          </tr>
        </thead>
        <tbody>
          {results.map((row, i) => {
            const isFailed = row.finish_reason === "max_tokens" || row.finish_reason === "error";
            return (
              <tr
                key={row.id || i}
                onClick={() => onSelectRow(row)}
                className={`border-b border-gray-100 cursor-pointer hover:bg-blue-50 ${
                  selectedId === row.id ? "bg-blue-50" : isFailed ? "bg-red-50" : i % 2 ? "bg-gray-50" : "bg-white"
                }`}
              >
                <td className="px-3 py-2.5 whitespace-nowrap text-blue-600">{row.start_time?.slice(0, 19)}</td>
                <td className="px-2 py-2.5">{modelBadge(row.model)}</td>
                <td className="px-2 py-2.5 text-gray-600">{row.call_type}</td>
                <td className="px-2 py-2.5">
                  <span className={row.finish_reason === "stop" ? "text-green-600" : "text-red-600"}>
                    {row.finish_reason}
                  </span>
                </td>
                <td className="px-2 py-2.5 text-right font-mono">{Number(row.total_tokens || 0).toLocaleString()}</td>
                <td className="px-2 py-2.5">{toolBadges(row.tool_names)}</td>
                <td className="px-2 py-2.5 text-gray-700 max-w-xs truncate">{row.user_message_preview}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
