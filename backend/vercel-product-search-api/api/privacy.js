import { privacyPage, sendPublicPage } from "./public-page.js";

export default function privacyHandler(request, response) {
  return sendPublicPage(request, response, privacyPage);
}
