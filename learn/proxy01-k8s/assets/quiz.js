/**
 * Minimal quiz widget for lessons.
 * Markup:
 * <div class="quiz" data-correct="1">
 *   <h3>Check</h3>
 *   <p class="prompt">...</p>
 *   <div class="options">
 *     <button type="button" class="option" data-i="0">...</button>
 *     ...
 *   </div>
 *   <p class="feedback" hidden></p>
 * </div>
 * data-correct = index of correct option (string).
 * Optional data-explain-correct / data-explain-wrong on .quiz.
 */
(function () {
  function wire(quiz) {
    const correct = Number(quiz.dataset.correct);
    const feedback = quiz.querySelector(".feedback");
    const explainOk = quiz.dataset.explainCorrect || "Correct.";
    const explainBad = quiz.dataset.explainWrong || "Not quite — try again, or ask the agent.";
    const buttons = [...quiz.querySelectorAll("button.option")];

    buttons.forEach((btn) => {
      btn.addEventListener("click", () => {
        const i = Number(btn.dataset.i);
        const ok = i === correct;
        buttons.forEach((b) => {
          b.disabled = true;
          if (Number(b.dataset.i) === correct) b.classList.add("correct");
        });
        if (!ok) btn.classList.add("wrong");
        feedback.hidden = false;
        feedback.textContent = ok ? explainOk : explainBad;
      });
    });
  }

  document.querySelectorAll(".quiz[data-correct]").forEach(wire);
})();
