const config = {
  apiEndpoint: import.meta.env.VITE_API_ENDPOINT || "",
  cognito: {
    userPoolId: import.meta.env.VITE_COGNITO_USER_POOL_ID || "",
    clientId: import.meta.env.VITE_COGNITO_CLIENT_ID || "",
    domain: import.meta.env.VITE_COGNITO_DOMAIN || "",
  },
};

export default config;
