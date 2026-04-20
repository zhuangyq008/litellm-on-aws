import { useState } from "react";
import useAuth from "./hooks/useAuth";
import useAuditQuery from "./hooks/useAuditQuery";
import Layout from "./components/Layout";
import FilterBar from "./components/FilterBar";
import ResultsTable from "./components/ResultsTable";
import DetailPanel from "./components/DetailPanel";
import Pagination from "./components/Pagination";

function LoginPage({ onLogin, error, completeNewPassword }) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [newPw, setNewPw] = useState("");
  const [challenge, setChallenge] = useState(null);

  const handleSubmit = async (e) => {
    e.preventDefault();
    const result = await onLogin(email, password);
    if (result?.newPasswordRequired) {
      setChallenge(result);
    }
  };

  if (challenge) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-gray-100">
        <form onSubmit={(e) => { e.preventDefault(); completeNewPassword(challenge.cognitoUser, newPw); }} className="bg-white p-8 rounded-lg shadow-md w-96">
          <h2 className="text-xl font-bold mb-4">Set New Password</h2>
          <input type="password" placeholder="New Password" value={newPw} onChange={(e) => setNewPw(e.target.value)} className="w-full border rounded px-3 py-2 mb-4" />
          <button type="submit" className="w-full bg-blue-600 text-white py-2 rounded font-semibold">Confirm</button>
        </form>
      </div>
    );
  }

  return (
    <div className="min-h-screen flex items-center justify-center bg-gray-100">
      <form onSubmit={handleSubmit} className="bg-white p-8 rounded-lg shadow-md w-96">
        <h2 className="text-xl font-bold mb-6">LiteLLM Audit Logs</h2>
        {error && <div className="bg-red-50 text-red-600 p-2 rounded mb-4 text-sm">{error}</div>}
        <input type="email" placeholder="Email" value={email} onChange={(e) => setEmail(e.target.value)} className="w-full border rounded px-3 py-2 mb-3" />
        <input type="password" placeholder="Password" value={password} onChange={(e) => setPassword(e.target.value)} className="w-full border rounded px-3 py-2 mb-4" />
        <button type="submit" className="w-full bg-blue-600 text-white py-2 rounded font-semibold hover:bg-blue-700">Sign In</button>
      </form>
    </div>
  );
}

export default function App() {
  const { user, loading: authLoading, error: authError, login, logout, getToken, completeNewPassword } = useAuth();
  const { results, loading, error, queryInfo, search, fetchRecord } = useAuditQuery(getToken);
  const [selectedRow, setSelectedRow] = useState(null);

  if (authLoading) {
    return <div className="min-h-screen flex items-center justify-center text-gray-400">Loading...</div>;
  }

  if (!user) {
    return <LoginPage onLogin={login} error={authError} completeNewPassword={completeNewPassword} />;
  }

  return (
    <Layout user={user} onLogout={logout}>
      <FilterBar onSearch={search} loading={loading} />
      {error && <div className="bg-red-50 text-red-600 px-5 py-2 text-sm">{error}</div>}
      <ResultsTable results={results} onSelectRow={setSelectedRow} selectedId={selectedRow?.id} />
      {selectedRow && <DetailPanel row={selectedRow} fetchRecord={fetchRecord} onClose={() => setSelectedRow(null)} />}
      <Pagination count={queryInfo?.count} />
    </Layout>
  );
}
