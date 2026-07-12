import { sendPublicPage, supportPage } from "./public-page.js";

export default function supportHandler(request, response) {
  return sendPublicPage(request, response, supportPage);
}
