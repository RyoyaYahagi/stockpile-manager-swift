import { privacyPage, sendPublicPage } from "./public-page.js";

export default function privacyHandler(request, response, env = {}) {
  return sendPublicPage(request, response, privacyPage(env));
}
