export default function Pagination({ count }) {
  return (
    <div className="px-5 py-3 border-t border-gray-200 bg-white flex justify-between items-center text-sm text-gray-500">
      <span>{count ?? 0} results</span>
    </div>
  );
}
