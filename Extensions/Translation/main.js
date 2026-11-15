// This is the complete editable behavior of the Translation tool.
// Save this file to reload only Translation; MacHelper stays running.
MacHelper.define({
  commands: {
    async translate(input) {
      const settings = input.settings || {};
      const prompt = MacHelper.readText("prompts/translate.txt");
      const response = await MacHelper.ai.transform({
        action: "translate",
        text: input.text,
        targetLanguage: settings.targetLanguage || "zh-CN",
        model: "", // Use MacHelper's shared provider/model choice.
        guidance: prompt + "\nWriting style: " + (settings.style || "natural")
      });
      // Customize formatting here, e.g. return {text: "译文：" + response.text}.
      return {text: response.text, title: "Translation"};
    }
  }
});
