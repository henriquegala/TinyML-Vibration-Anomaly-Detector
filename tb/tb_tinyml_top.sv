`timescale 1ns/1ps
// ============================================================================
// tb_tinyml_top.sv
// Testbench auto-checking para o acelerador TinyML (mac_tree + activation_unit)
//
// Latência do pipeline (importante para o alinhamento das verificações):
//   mac_tree        -> 2 ciclos de registo (Estagio 1 + Estagio 2)
//   activation_unit -> 1 ciclo de registo (Etapa 3)
//   Total           -> 3 ciclos entre valid_in e o valid_out/neuron_out correspondente
//
//   anomaly_alert tem +1 CICLO EXTRA face a valid_out/neuron_out (4 ciclos
//   totais desde valid_in), por decisao de arquitetura: e calculado num
//   always_ff separado dentro do tinyml_top, que reage a valid_out (ja
//   registado) em vez de ser combinacional a partir de neuron_out.
//   Ver docs/ para a discussao completa e a proposta de versao combinacional
//   (sem este ciclo extra) para um projeto futuro.
// ============================================================================

module tb_tinyml_top;

    // ---------------------------------------------------------------
    // Parametros do DUT (mantidos iguais aos defaults do projeto)
    // ---------------------------------------------------------------
    localparam int NUM_INPUTS      = 4;
    localparam int DATA_WIDTH      = 16;
    localparam int FRAC_BITS       = 8;
    localparam int ACTIVATION_TYPE = 1; // 0=Linear 1=ReLU 2=LeakyReLU 3=HardSwish 4=Sigmoide

    localparam int ACC_WIDTH = (2*DATA_WIDTH) + $clog2(NUM_INPUTS+1);
    localparam int PIPE_LATENCY = 3; // 2 (mac_tree) + 1 (activation_unit)

    // Fator de escala Q8.8 -> usado só para construir estimulos legiveis
    localparam int Q88_ONE = (1 << FRAC_BITS); // 256 = 1.0 em Q8.8

    // ---------------------------------------------------------------
    // Sinais de ligacao ao DUT
    // ---------------------------------------------------------------
    logic clk;
    logic rst_n;
    logic valid_in;

    logic signed [DATA_WIDTH-1:0] inputs  [NUM_INPUTS-1:0];
    logic signed [DATA_WIDTH-1:0] weights [NUM_INPUTS-1:0];
    logic signed [DATA_WIDTH-1:0] bias;

    logic signed [DATA_WIDTH-1:0] target_expected;
    logic signed [DATA_WIDTH-1:0] threshold;

    logic valid_out;
    logic signed [DATA_WIDTH-1:0] neuron_out;
    logic anomaly_alert;

    // ---------------------------------------------------------------
    // Fila (queue) para guardar os estimulos e os valores esperados,
    // para que possamos verificar cada resultado quando valid_out chegar,
    // mesmo em fluxo continuo (varios valid_in seguidos, sem "buracos").
    // ---------------------------------------------------------------
    typedef struct {
        logic signed [DATA_WIDTH-1:0] inputs_snapshot  [NUM_INPUTS-1:0];
        logic signed [DATA_WIDTH-1:0] weights_snapshot [NUM_INPUTS-1:0];
        logic signed [DATA_WIDTH-1:0] bias_snapshot;
        logic signed [DATA_WIDTH-1:0] target_snapshot;
        logic signed [DATA_WIDTH-1:0] threshold_snapshot;
        string label;
    } stimulus_t;

    stimulus_t pending_queue[$];

    int errors = 0;
    int checks = 0;

    // ---------------------------------------------------------------
    // Instanciacao do DUT
    // ---------------------------------------------------------------
    tinyml_top #(
        .num_inputs      (NUM_INPUTS),
        .data_width      (DATA_WIDTH),
        .frac_bits       (FRAC_BITS),
        .activation_type (ACTIVATION_TYPE)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .valid_in        (valid_in),
        .inputs          (inputs),
        .weights         (weights),
        .bias            (bias),
        .target_expected (target_expected),
        .threshold       (threshold),
        .valid_out       (valid_out),
        .neuron_out      (neuron_out),
        .anomaly_alert   (anomaly_alert)
    );

    // ---------------------------------------------------------------
    // Geracao de clock: 100 MHz (periodo de 10 ns)
    // ---------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---------------------------------------------------------------
    // Modelo de referencia em software (Q8.8), espelha a matematica
    // do mac_tree + activation_unit para calcularmos o valor esperado.
    // ---------------------------------------------------------------
    function automatic logic signed [DATA_WIDTH-1:0] expected_neuron_out(
        input logic signed [DATA_WIDTH-1:0] in_vec  [NUM_INPUTS-1:0],
        input logic signed [DATA_WIDTH-1:0] w_vec   [NUM_INPUTS-1:0],
        input logic signed [DATA_WIDTH-1:0] bias_val
    );
        longint signed acc_q1616; // acumulador largo o suficiente p/ simulacao
        longint signed q88_clamped;
        longint signed v_clamp, p1, p2;
        int teto_pos, chao_neg;
        begin
            // --- replica o mac_tree: soma dos produtos + bias alinhado ---
            acc_q1616 = longint'(bias_val) <<< FRAC_BITS;
            for (int i = 0; i < NUM_INPUTS; i++) begin
                acc_q1616 = acc_q1616 + (longint'(in_vec[i]) * longint'(w_vec[i]));
            end

            // --- replica a Etapa 1 da activation_unit: clamp para Q8.8 ---
            teto_pos =  (1 << (DATA_WIDTH-1)) - 1; //  32767
            chao_neg = -(1 << (DATA_WIDTH-1));     // -32768
            q88_clamped = acc_q1616 >>> FRAC_BITS; // janela [23:8] equivalente
            if (q88_clamped > teto_pos) q88_clamped = teto_pos;
            if (q88_clamped < chao_neg) q88_clamped = chao_neg;

            // --- replica a Etapa 2: funcao de ativacao ---
            case (ACTIVATION_TYPE)
                0: expected_neuron_out = DATA_WIDTH'(q88_clamped);                       // Linear
                1: expected_neuron_out = (q88_clamped < 0) ? '0 : DATA_WIDTH'(q88_clamped); // ReLU
                2: expected_neuron_out = (q88_clamped < 0)
                        ? DATA_WIDTH'(q88_clamped >>> 3)
                        : DATA_WIDTH'(q88_clamped);                                       // LeakyReLU
                3: begin // Hard-Swish
                    if (q88_clamped <= -768) v_clamp = 0;
                    else if (q88_clamped >= 768) v_clamp = 1536;
                    else v_clamp = q88_clamped + 768;
                    p1 = q88_clamped * v_clamp;
                    p2 = p1 * 10923;
                    expected_neuron_out = DATA_WIDTH'(p2 >>> 24);
                end
                default: expected_neuron_out = DATA_WIDTH'(q88_clamped); // Sigmoide nao verificada por LUT aqui
            endcase
        end
    endfunction

    // ---------------------------------------------------------------
    // Task: aplica um estimulo durante 1 ciclo, com valid_in = 1,
    // e regista-o na fila para verificacao futura.
    // ---------------------------------------------------------------
    task automatic drive_sample(
        input logic signed [DATA_WIDTH-1:0] in_vec [NUM_INPUTS-1:0],
        input logic signed [DATA_WIDTH-1:0] w_vec  [NUM_INPUTS-1:0],
        input logic signed [DATA_WIDTH-1:0] bias_val,
        input logic signed [DATA_WIDTH-1:0] target_val,
        input logic signed [DATA_WIDTH-1:0] threshold_val,
        input string label
    );
        stimulus_t s;
        begin
            inputs          = in_vec;
            weights         = w_vec;
            bias            = bias_val;
            target_expected = target_val;
            threshold       = threshold_val;
            valid_in        = 1'b1;

            s.inputs_snapshot     = in_vec;
            s.weights_snapshot    = w_vec;
            s.bias_snapshot       = bias_val;
            s.target_snapshot     = target_val;
            s.threshold_snapshot  = threshold_val;
            s.label               = label;
            pending_queue.push_back(s);

            @(posedge clk);
        end
    endtask

    // Task para inserir uma "bolha" (valid_in = 0 durante 1 ciclo)
    task automatic drive_bubble();
        begin
            valid_in = 1'b0;
            @(posedge clk);
        end
    endtask

    // ---------------------------------------------------------------
    // Registo do valid_out atrasado 1 ciclo: usado para verificar
    // anomaly_alert, que por decisao de arquitetura (documentada em
    // docs/) tem +1 ciclo de latencia face a valid_out/neuron_out,
    // porque e calculado num always_ff separado dentro do tinyml_top.
    // ---------------------------------------------------------------
    logic valid_out_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) valid_out_d <= 1'b0;
        else        valid_out_d <= valid_out;
    end

    // Fila separada só para o valor esperado de anomaly_alert, que
    // "viaja" 1 ciclo a mais que o resto da amostra antes de ser
    // verificado (ver bloco abaixo).
    logic alert_queue[$];

    // ---------------------------------------------------------------
    // Processo de verificacao: corre em paralelo, monitoriza valid_out
    // e compara com o primeiro elemento da fila (ordem FIFO garante
    // que nao ha mistura de amostras mesmo em fluxo continuo).
    // ---------------------------------------------------------------
    always @(posedge clk) begin
        // --- Verificacao de neuron_out: alinhada com valid_out ---
        if (rst_n && valid_out) begin
            stimulus_t s;
            logic signed [DATA_WIDTH-1:0] expected_out;
            logic signed [DATA_WIDTH:0]   expected_diff;
            logic signed [DATA_WIDTH:0]   expected_abs;
            logic expected_alert;

            if (pending_queue.size() == 0) begin
                $error("[%0t] valid_out ativo sem amostra pendente na fila!", $time);
                errors++;
            end else begin
                s = pending_queue.pop_front();
                expected_out = expected_neuron_out(s.inputs_snapshot, s.weights_snapshot, s.bias_snapshot);

                expected_diff  = expected_out - s.target_snapshot;
                expected_abs   = (expected_diff < 0) ? -expected_diff : expected_diff;
                expected_alert = (expected_abs > s.threshold_snapshot);

                checks++;
                if (neuron_out !== expected_out) begin
                    $error("[%0t] MISMATCH neuron_out (%s): esperado=%0d obtido=%0d",
                            $time, s.label, expected_out, neuron_out);
                    errors++;
                end else begin
                    $display("[%0t] OK  neuron_out (%s): valor=%0d",
                              $time, s.label, neuron_out);
                end

                // Guarda o valor esperado do alerta para verificar
                // no PROXIMO ciclo (+1 latencia documentada).
                alert_queue.push_back(expected_alert);
            end
        end

        // --- Verificacao de anomaly_alert: alinhada com valid_out_d (1 ciclo depois) ---
        if (rst_n && valid_out_d) begin
            logic expected_alert;

            if (alert_queue.size() == 0) begin
                $error("[%0t] valid_out_d ativo sem alerta esperado pendente na fila!", $time);
                errors++;
            end else begin
                expected_alert = alert_queue.pop_front();
                if (anomaly_alert !== expected_alert) begin
                    $error("[%0t] MISMATCH anomaly_alert: esperado=%0b obtido=%0b",
                            $time, expected_alert, anomaly_alert);
                    errors++;
                end else begin
                    $display("[%0t] OK  anomaly_alert: valor=%0b", $time, anomaly_alert);
                end
            end
        end
    end

    // ---------------------------------------------------------------
    // Sequencia principal de testes
    // ---------------------------------------------------------------
    initial begin
        logic signed [DATA_WIDTH-1:0] in_a  [NUM_INPUTS-1:0];
        logic signed [DATA_WIDTH-1:0] w_a   [NUM_INPUTS-1:0];
        logic signed [DATA_WIDTH-1:0] in_b  [NUM_INPUTS-1:0];
        logic signed [DATA_WIDTH-1:0] w_b   [NUM_INPUTS-1:0];
        logic signed [DATA_WIDTH-1:0] in_c  [NUM_INPUTS-1:0];
        logic signed [DATA_WIDTH-1:0] w_c   [NUM_INPUTS-1:0];

        // --- Reset ---
        rst_n    = 1'b0;
        valid_in = 1'b0;
        for (int i = 0; i < NUM_INPUTS; i++) begin
            inputs[i]  = '0;
            weights[i] = '0;
        end
        bias            = '0;
        target_expected = '0;
        threshold       = '0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // -----------------------------------------------------------
        // Teste 1: amostra unica, valores simples, sem anomalia
        // 1.0 em Q8.8 = 256
        // -----------------------------------------------------------
        for (int i = 0; i < NUM_INPUTS; i++) begin
            in_a[i] = 16'sd256; // 1.0
            w_a[i]  = 16'sd128; // 0.5
        end
        drive_sample(in_a, w_a, 16'sd0, 16'sd512, 16'sd64, "T1_simples");
        drive_bubble();

        // -----------------------------------------------------------
        // Teste 2: valores que devem disparar anomaly_alert
        // (target muito longe do resultado esperado)
        // -----------------------------------------------------------
        for (int i = 0; i < NUM_INPUTS; i++) begin
            in_b[i] = 16'sd256;
            w_b[i]  = 16'sd256; // 1.0
        end
        drive_sample(in_b, w_b, 16'sd0, -16'sd3000, 16'sd64, "T2_anomalia");
        drive_bubble();

        // -----------------------------------------------------------
        // Teste 3: entradas negativas (testa ReLU/clamping do lado negativo)
        // -----------------------------------------------------------
        for (int i = 0; i < NUM_INPUTS; i++) begin
            in_c[i] = -16'sd256; // -1.0
            w_c[i]  = 16'sd256;  //  1.0
        end
        drive_sample(in_c, w_c, 16'sd0, 16'sd0, 16'sd64, "T3_negativo_ReLU");
        drive_bubble();

        // -----------------------------------------------------------
        // Teste 4: streaming continuo - 3 amostras back-to-back
        // (sem bolhas entre elas), para confirmar que a fila FIFO
        // nao mistura amostras mesmo com o pipeline cheio.
        // -----------------------------------------------------------
        drive_sample(in_a, w_a, 16'sd0,  16'sd512, 16'sd64, "T4_stream_0");
        drive_sample(in_b, w_b, 16'sd0, -16'sd3000, 16'sd64, "T4_stream_1");
        drive_sample(in_c, w_c, 16'sd0,  16'sd0,   16'sd64, "T4_stream_2");
        drive_bubble();

        // Espera o pipeline esvaziar (latencia + 1 ciclo extra do
        // anomaly_alert + margem)
        repeat (PIPE_LATENCY + 1 + 5) @(posedge clk);

        // -----------------------------------------------------------
        // Relatorio final
        // -----------------------------------------------------------
        if (pending_queue.size() != 0) begin
            $error("Fila de amostras nao vazia no fim do teste (%0d pendentes) - possivel perda de valid_out.",
                    pending_queue.size());
            errors++;
        end
        if (alert_queue.size() != 0) begin
            $error("Fila de alertas nao vazia no fim do teste (%0d pendentes) - possivel perda de valid_out_d.",
                    alert_queue.size());
            errors++;
        end

        $display("--------------------------------------------------");
        $display("Verificacoes realizadas: %0d", checks);
        $display("Erros encontrados      : %0d", errors);
        if (errors == 0)
            $display("RESULTADO: TODOS OS TESTES PASSARAM");
        else
            $display("RESULTADO: FALHAS DETETADAS");
        $display("--------------------------------------------------");

        $finish;
    end

    // ---------------------------------------------------------------
    // Timeout de seguranca (evita simulacao presa indefinidamente)
    // ---------------------------------------------------------------
    initial begin
        #10000;
        $error("TIMEOUT: simulacao nao terminou a tempo.");
        $finish;
    end

endmodule