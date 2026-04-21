import { useState, useEffect, useCallback } from "react";
import {
  CognitoUserPool,
  CognitoUser,
  AuthenticationDetails,
} from "amazon-cognito-identity-js";
import config from "../config";

const userPool = new CognitoUserPool({
  UserPoolId: config.cognito.userPoolId,
  ClientId: config.cognito.clientId,
});

export default function useAuth() {
  const [user, setUser] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    const currentUser = userPool.getCurrentUser();
    if (currentUser) {
      currentUser.getSession((err, session) => {
        if (err || !session.isValid()) {
          setUser(null);
        } else {
          setUser({
            email: currentUser.getUsername(),
            token: session.getAccessToken().getJwtToken(),
            idToken: session.getIdToken().getJwtToken(),
          });
        }
        setLoading(false);
      });
    } else {
      setLoading(false);
    }
  }, []);

  const login = useCallback((email, password) => {
    return new Promise((resolve, reject) => {
      const cognitoUser = new CognitoUser({
        Username: email,
        Pool: userPool,
      });
      const authDetails = new AuthenticationDetails({
        Username: email,
        Password: password,
      });

      cognitoUser.authenticateUser(authDetails, {
        onSuccess: (session) => {
          const userData = {
            email,
            token: session.getAccessToken().getJwtToken(),
            idToken: session.getIdToken().getJwtToken(),
          };
          setUser(userData);
          setError(null);
          resolve(userData);
        },
        onFailure: (err) => {
          setError(err.message);
          reject(err);
        },
        newPasswordRequired: (userAttributes) => {
          resolve({ newPasswordRequired: true, cognitoUser, userAttributes });
        },
      });
    });
  }, []);

  const completeNewPassword = useCallback((cognitoUser, newPassword) => {
    return new Promise((resolve, reject) => {
      cognitoUser.completeNewPasswordChallenge(newPassword, {}, {
        onSuccess: (session) => {
          const userData = {
            email: cognitoUser.getUsername(),
            token: session.getAccessToken().getJwtToken(),
            idToken: session.getIdToken().getJwtToken(),
          };
          setUser(userData);
          resolve(userData);
        },
        onFailure: (err) => {
          setError(err.message);
          reject(err);
        },
      });
    });
  }, []);

  const logout = useCallback(() => {
    const currentUser = userPool.getCurrentUser();
    if (currentUser) currentUser.signOut();
    setUser(null);
  }, []);

  const getToken = useCallback(() => {
    return new Promise((resolve) => {
      const currentUser = userPool.getCurrentUser();
      if (!currentUser) return resolve(null);
      currentUser.getSession((err, session) => {
        if (err || !session.isValid()) return resolve(null);
        resolve(session.getIdToken().getJwtToken());
      });
    });
  }, []);

  return { user, loading, error, login, logout, getToken, completeNewPassword };
}
