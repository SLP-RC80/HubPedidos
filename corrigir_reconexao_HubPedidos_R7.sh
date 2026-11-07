#!/usr/bin/env bash
set -Eeuo pipefail
cd /workspaces/HubPedidos
python3 - <<'PY'
from pathlib import Path
import shutil
import tempfile

arquivo = Path('HubPedidos.Relatorio7.Cliente/Program.cs')
if not arquivo.is_file():
    raise SystemExit('ERRO: Programa cliente R7 nao encontrado: ' + str(arquivo))
codigo = arquivo.read_text(encoding='utf-8')

old_flag = 'var entrouEmReconexao = false;'
old_closed = 'alice.Closed += _ => { Console.WriteLine("R7.02 ESTADO: Desconectado"); return Task.CompletedTask; };'
old_validation = '''if (!entrouEmReconexao) throw new Exception("Callback Reconnecting nao foi observado.");
Console.WriteLine("R7.02 RECONEXAO: WithAutomaticReconnect=SIM; reassinatura=SIM; GET autoritativo=SIM");'''
new_closed = '''alice.Closed += async erro =>
{
    // Em um encerramento normal, o SignalR pode ir direto a Closed e nao acionar
    // WithAutomaticReconnect. Nesse caso, recuperar explicitamente a conexao.
    if (reconciliado.Task.IsCompleted) return;
    Console.WriteLine("R7.02 ESTADO: Desconectado; iniciando recuperacao manual");
    Exception? ultimaFalha = erro;
    for (var tentativa = 1; tentativa <= 5; tentativa++)
    {
        await Task.Delay(tentativa == 1 ? 300 : 1000);
        try
        {
            await alice.StartAsync();
            // A nova conexao nao herda os grupos da anterior.
            await alice.InvokeAsync("Acompanhar", pedidoId);
            using var estado = await aliceHttp.GetAsync($"/api/v1/pedidos/{pedidoId}");
            estado.EnsureSuccessStatusCode();
            using var documento = JsonDocument.Parse(await estado.Content.ReadAsStringAsync());
            recuperacaoManual = true;
            Console.WriteLine($"R7.02 ESTADO: Conectado; modo=MANUAL_APOS_FECHAMENTO; reingresso=SIM; GET HTTP={(int)estado.StatusCode}; versao_atual={documento.RootElement.GetProperty("versao").GetInt32()}; reconciliado=SIM");
            reconciliado.TrySetResult(true);
            return;
        }
        catch (Exception falha)
        {
            ultimaFalha = falha;
            Console.WriteLine($"R7.02 TENTATIVA: {tentativa}/5; falha={falha.GetType().Name}");
        }
    }
    reconciliado.TrySetException(ultimaFalha ?? new Exception("Falha na recuperacao do SignalR"));
};'''
new_validation = '''if (!entrouEmReconexao && !recuperacaoManual)
    throw new Exception("Nenhuma reconexao foi observada.");
var modo = recuperacaoManual ? "MANUAL_APOS_FECHAMENTO" : "AUTOMATICA";
Console.WriteLine($"R7.02 RECONEXAO: modo={modo}; WithAutomaticReconnect_configurado=SIM; reassinatura=SIM; GET autoritativo=SIM");'''

pares = [(old_flag, old_flag+'\nvar recuperacaoManual = false;'),
         (old_closed, new_closed),
         (old_validation, new_validation)]
for antes, _ in pares:
    if codigo.count(antes) != 1:
        raise SystemExit('ERRO: trecho esperado nao encontrado uma unica vez. Nada foi alterado: '+antes[:70])

backup = Path(tempfile.mkdtemp(prefix='hubpedidos-r7-')) / 'Program.cs'
shutil.copy2(arquivo, backup)
for antes, depois in pares:
    codigo = codigo.replace(antes, depois, 1)
arquivo.write_text(codigo, encoding='utf-8')
print('R7.02 corrigido:', arquivo)
print('Copia de seguranca temporaria:', backup)
print('Automatic reconnect mantido; fallback manual somente apos Closed.')
PY

echo '=== Compilar o cliente R7 ==='
dotnet build HubPedidos.Relatorio7.Cliente/HubPedidos.Relatorio7.Cliente.csproj -c Release
printf '\nAgora execute em outro terminal (com a API ativa):\n'
printf 'bash HubPedidos.Relatorio7/rodar_cliente.sh\n'
