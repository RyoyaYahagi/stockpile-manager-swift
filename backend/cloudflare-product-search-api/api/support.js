import { sendPublicPage, supportPage } from "./public-page.js";

export default function supportHandler(request, response, env = {}) {
  return sendPublicPage(request, response, supportPage(env));
}
