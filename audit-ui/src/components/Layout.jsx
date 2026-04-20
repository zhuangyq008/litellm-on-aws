export default function Layout({ user, onLogout, children }) {
  return (
    <div className="min-h-screen bg-gray-50">
      <nav className="bg-gray-900 text-white px-5 py-3 flex justify-between items-center">
        <span className="font-bold text-lg">LiteLLM Audit Logs</span>
        <div className="text-sm text-gray-400">
          {user?.email}
          <button
            onClick={onLogout}
            className="ml-4 text-gray-300 hover:text-white"
          >
            Logout
          </button>
        </div>
      </nav>
      {children}
    </div>
  );
}
