import { useState, useCallback, useRef } from "react";
import config from "../config";

export default function useAuditQuery(getToken) {
  const [results, setResults] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);
  const [queryInfo, setQueryInfo] = useState(null);
  const pollingRef = useRef(null);

  const apiCall = useCallback(
    async (path, options = {}) => {
      const token = await getToken();
      const res = await fetch(`${config.apiEndpoint}${path}`, {
        ...options,
        headers: {
          "Content-Type": "application/json",
          Authorization: token,
          ...options.headers,
        },
      });
      if (!res.ok) throw new Error(`API error: ${res.status}`);
      return res.json();
    },
    [getToken]
  );

  const search = useCallback(
    async (filters) => {
      setLoading(true);
      setError(null);
      setResults([]);

      try {
        const { execution_id } = await apiCall("/api/query", {
          method: "POST",
          body: JSON.stringify(filters),
        });

        const poll = async () => {
          const data = await apiCall(`/api/query/${execution_id}`);
          if (data.status === "SUCCEEDED") {
            setResults(data.results || []);
            setQueryInfo({ count: data.count });
            setLoading(false);
          } else if (data.status === "FAILED") {
            setError(data.error || "Query failed");
            setLoading(false);
          } else {
            pollingRef.current = setTimeout(poll, 1000);
          }
        };
        await poll();
      } catch (err) {
        setError(err.message);
        setLoading(false);
      }
    },
    [apiCall]
  );

  const fetchRecord = useCallback(
    async (recordId) => {
      const data = await apiCall(`/api/record/${recordId}`);
      return data.record;
    },
    [apiCall]
  );

  return { results, loading, error, queryInfo, search, fetchRecord };
}
