import { useState, useEffect } from "react";

function InfoCard({ label, value, mono }) {
  return (
    <div className="bg-white p-3 rounded-lg border border-gray-200">
      <div className="text-xs text-gray-400 uppercase">{label}</div>
      <div className={`font-semibold mt-1 ${mono ? "font-mono text-xs" : ""}`}>{value || "\u2014"}</div>
    </div>
  );
}

const TABS = ["User Message", "Response", "Raw Request", "Raw Response"];

export default function DetailPanel({ row, fetchRecord, onClose }) {
  const [activeTab, setActiveTab] = useState(0);
  const [fullRecord, setFullRecord] = useState(null);

  useEffect(() => {
    if (row?.id && fetchRecord) {
      fetchRecord(row.id).then(setFullRecord).catch(() => setFullRecord(null));
    }
  }, [row?.id, fetchRecord]);

  if (!row) return null;

  const cachedPct = row.prompt_tokens > 0
    ? ((Number(row.cached_tokens) / Number(row.prompt_tokens)) * 100).toFixed(1)
    : "0";

  const tabContent = () => {
    if (activeTab === 0) return row.user_message_preview || "(empty)";
    if (activeTab === 1) return row.response_preview || "(empty)";
    if (activeTab === 2) return fullRecord?.raw_messages || "Loading...";
    if (activeTab === 3) return fullRecord?.raw_response || "Loading...";
  };

  return (
    <div className="bg-gray-100 border-t border-gray-300 p-5">
      <div className="flex justify-between items-center mb-4">
        <div>
          <span className="text-lg font-bold">Request Detail</span>
          <span className="ml-3 text-xs text-gray-400 font-mono">{row.id}</span>
        </div>
        <button onClick={onClose} className="border border-gray-300 rounded px-3 py-1 text-sm hover:bg-white">Close</button>
      </div>

      <div className="grid grid-cols-3 gap-3 mb-5">
        <InfoCard label="Model" value={row.model} />
        <InfoCard label="Time" value={row.start_time?.slice(0, 19)} />
        <InfoCard label="Call Type" value={row.call_type} />
        <InfoCard label="Tokens (In / Out / Total)" value={`${Number(row.prompt_tokens).toLocaleString()} / ${Number(row.completion_tokens).toLocaleString()} / ${Number(row.total_tokens).toLocaleString()}`} mono />
        <InfoCard label="Cached Tokens" value={`${Number(row.cached_tokens).toLocaleString()} (${cachedPct}%)`} mono />
        <InfoCard label="Finish Reason" value={row.finish_reason} />
        <InfoCard label="Session ID" value={row.session_id} mono />
        <InfoCard label="Device ID" value={row.device_id} mono />
        <InfoCard label="Source IP" value={row.source_ip} mono />
      </div>

      <div className="flex border-b-2 border-gray-200 mb-4">
        {TABS.map((tab, i) => (
          <button
            key={tab}
            onClick={() => setActiveTab(i)}
            className={`px-4 py-2 text-sm ${
              activeTab === i ? "border-b-2 border-blue-600 text-blue-600 font-semibold -mb-0.5" : "text-gray-500"
            }`}
          >
            {tab}
          </button>
        ))}
      </div>

      <pre className="bg-gray-800 text-gray-200 p-4 rounded-lg text-xs font-mono leading-relaxed max-h-64 overflow-auto whitespace-pre-wrap">
        {tabContent()}
      </pre>
    </div>
  );
}
