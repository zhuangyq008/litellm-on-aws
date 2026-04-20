import { useState } from "react";

const today = new Date().toISOString().slice(0, 10);
const weekAgo = new Date(Date.now() - 7 * 86400000).toISOString().slice(0, 10);

const MODELS = [
  "All Models",
  "us.anthropic.claude-opus-4-6-v1",
  "us.anthropic.claude-sonnet-4-6",
  "us.anthropic.claude-haiku-4-5-20251001-v1:0",
];
const CALL_TYPES = ["All Types", "anthropic_messages", "acompletion", "aembedding"];
const FINISH_REASONS = ["All", "stop", "max_tokens", "tool_use"];

export default function FilterBar({ onSearch, loading }) {
  const [filters, setFilters] = useState({
    start_date: weekAgo,
    end_date: today,
    model: "",
    call_type: "",
    session_id: "",
    finish_reason: "",
    device_id: "",
    source_ip: "",
    min_total_tokens: "",
    has_tool_calls: false,
    keyword: "",
  });

  const update = (key, value) =>
    setFilters((prev) => ({ ...prev, [key]: value }));

  const handleSearch = () => {
    const params = { start_date: filters.start_date, end_date: filters.end_date };
    if (filters.model) params.model = filters.model;
    if (filters.call_type) params.call_type = filters.call_type;
    if (filters.session_id) params.session_id = filters.session_id;
    if (filters.finish_reason) params.finish_reason = filters.finish_reason;
    if (filters.device_id) params.device_id = filters.device_id;
    if (filters.source_ip) params.source_ip = filters.source_ip;
    if (filters.min_total_tokens) params.min_total_tokens = parseInt(filters.min_total_tokens, 10);
    if (filters.has_tool_calls) params.has_tool_calls = true;
    if (filters.keyword) params.keyword = filters.keyword;
    onSearch(params);
  };

  const inputCls = "border border-gray-300 rounded px-2 py-1.5 text-sm";
  const labelCls = "text-xs text-gray-500 uppercase mb-1";

  return (
    <div className="bg-white border-b border-gray-200 px-5 py-4">
      <div className="flex flex-wrap gap-3 items-end">
        <div>
          <div className={labelCls}>Start Date</div>
          <input type="date" className={inputCls} value={filters.start_date} onChange={(e) => update("start_date", e.target.value)} />
        </div>
        <div>
          <div className={labelCls}>End Date</div>
          <input type="date" className={inputCls} value={filters.end_date} onChange={(e) => update("end_date", e.target.value)} />
        </div>
        <div>
          <div className={labelCls}>Model</div>
          <select className={inputCls + " min-w-[180px]"} value={filters.model} onChange={(e) => update("model", e.target.value)}>
            {MODELS.map((m) => (
              <option key={m} value={m === "All Models" ? "" : m}>{m}</option>
            ))}
          </select>
        </div>
        <div>
          <div className={labelCls}>Call Type</div>
          <select className={inputCls + " min-w-[140px]"} value={filters.call_type} onChange={(e) => update("call_type", e.target.value)}>
            {CALL_TYPES.map((t) => (
              <option key={t} value={t === "All Types" ? "" : t}>{t}</option>
            ))}
          </select>
        </div>
        <div>
          <div className={labelCls}>Finish Reason</div>
          <select className={inputCls} value={filters.finish_reason} onChange={(e) => update("finish_reason", e.target.value)}>
            {FINISH_REASONS.map((r) => (
              <option key={r} value={r === "All" ? "" : r}>{r}</option>
            ))}
          </select>
        </div>
        <button onClick={handleSearch} disabled={loading} className="bg-blue-600 text-white px-5 py-1.5 rounded text-sm font-semibold hover:bg-blue-700 disabled:opacity-50">
          {loading ? "Searching..." : "Search"}
        </button>
      </div>
      <div className="flex flex-wrap gap-3 items-end mt-3 pt-3 border-t border-dashed border-gray-200">
        <div>
          <div className={labelCls}>Session ID</div>
          <input className={inputCls + " w-48"} placeholder="f61cee15-..." value={filters.session_id} onChange={(e) => update("session_id", e.target.value)} />
        </div>
        <div>
          <div className={labelCls}>Device ID</div>
          <input className={inputCls + " w-48"} placeholder="8d6ae821..." value={filters.device_id} onChange={(e) => update("device_id", e.target.value)} />
        </div>
        <div>
          <div className={labelCls}>Source IP</div>
          <input className={inputCls + " w-36"} placeholder="44.219.177.250" value={filters.source_ip} onChange={(e) => update("source_ip", e.target.value)} />
        </div>
        <div>
          <div className={labelCls}>Min Tokens</div>
          <input type="number" className={inputCls + " w-24"} placeholder="1000" value={filters.min_total_tokens} onChange={(e) => update("min_total_tokens", e.target.value)} />
        </div>
        <label className="flex items-center gap-1.5 pb-0.5">
          <input type="checkbox" checked={filters.has_tool_calls} onChange={(e) => update("has_tool_calls", e.target.checked)} />
          <span className="text-sm text-gray-600">Has Tool Calls</span>
        </label>
        <div>
          <div className={labelCls}>Keyword</div>
          <input className={inputCls + " w-40"} placeholder="Search previews..." value={filters.keyword} onChange={(e) => update("keyword", e.target.value)} />
        </div>
      </div>
    </div>
  );
}
